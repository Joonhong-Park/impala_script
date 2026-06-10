#!/bin/bash

# ==============================================================
# 멀티 클러스터 Impala 쿼리 실행기
# 사용법: ./impala_query_executor.sh -q "쿼리문" | -f sql파일 [-c 번호(쉼표구분)]
# ==============================================================

# 클러스터 호스트 (번호가 키 — 항목 주석 처리해도 나머지 번호 유지)
declare -A CLUSTER_HOSTS
CLUSTER_HOSTS[1]="host1.example.com"
CLUSTER_HOSTS[2]="host2.example.com"
CLUSTER_HOSTS[3]="host3.example.com"
CLUSTER_HOSTS[4]="host4.example.com"
CLUSTER_HOSTS[5]="host5.example.com"
IMPALA_USER="impala"
IMPALA_PASS="passwd"

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="$(cd "$(dirname "$0")" && pwd)/logs"
mkdir -p "$LOG_DIR"

# [변경] MAX_NUM 제거 — 연관 배열은 크기로 범위 검사 불가, 키 존재 여부로 대체

# --------------------------------------------------------------
usage() {
    cat <<EOF

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -q <query>    실행할 쿼리문
  -f <file>     실행할 SQL 파일
  -c <numbers>  클러스터 번호 - 쉼표 구분 (기본값: 전체)
  -h            도움말

Clusters:
$(for i in $(echo "${!CLUSTER_HOSTS[@]}" | tr ' ' '\n' | sort -n); do printf "  %d) %s\n" "$i" "${CLUSTER_HOSTS[$i]}"; done) # [변경] 키를 번호로 직접 사용, sort -n 으로 순서 보장

Examples:
  $SCRIPT_NAME -q "SELECT count(*) FROM db.table"
  $SCRIPT_NAME -f ./add_partition.sql
  $SCRIPT_NAME -q "REFRESH db.table" -c 1,3

EOF
    exit 1
}

# --------------------------------------------------------------
QUERY="" SQL_FILE="" TARGET_INPUT=""

while getopts ":q:f:c:h" opt; do
    case $opt in
        q) QUERY="$OPTARG" ;;
        f) SQL_FILE="$OPTARG" ;;
        c) TARGET_INPUT="$OPTARG" ;;
        h) usage ;;
        :) echo "[ERROR] -$OPTARG 옵션에 값이 필요합니다."; usage ;;
        \?) echo "[ERROR] 알 수 없는 옵션: -$OPTARG"; usage ;;
    esac
done

[[ -z "$QUERY" && -z "$SQL_FILE" ]] && { echo "[ERROR] -q 또는 -f 중 하나는 필수입니다."; usage; }
[[ -n "$QUERY" && -n "$SQL_FILE" ]] && { echo "[ERROR] -q 와 -f 는 동시에 사용할 수 없습니다."; usage; }

if [[ -n "$SQL_FILE" ]]; then
    SQL_FILE="$(realpath "$SQL_FILE" 2>/dev/null || echo "$SQL_FILE")"
    [[ ! -f "$SQL_FILE" ]] && { echo "[ERROR] SQL 파일을 찾을 수 없습니다: $SQL_FILE"; exit 1; }
fi

if [[ -n "$QUERY" ]]; then
    INPUT_OPT=(-q "$QUERY"); INPUT_LABEL="쿼리  : $QUERY"; INPUT_RETRY="-q \"$QUERY\""
else
    INPUT_OPT=(-f "$SQL_FILE"); INPUT_LABEL="파일  : $SQL_FILE"; INPUT_RETRY="-f $SQL_FILE"
fi

# --------------------------------------------------------------
TARGET_NUMS=()

if [[ -z "$TARGET_INPUT" ]]; then
    for i in $(echo "${!CLUSTER_HOSTS[@]}" | tr ' ' '\n' | sort -n); do TARGET_NUMS+=("$i"); done # [변경] 키를 번호로 직접 사용
else
    IFS=',' read -ra selected <<< "$TARGET_INPUT"
    for num in "${selected[@]}"; do
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [[ -z "${CLUSTER_HOSTS[$num]+x}" ]]; then # [변경] 범위 비교 → 키 존재 여부 확인
            echo "[WARN] 유효하지 않은 번호: '$num' (건너뜀, 정의된 클러스터 번호가 아님)"
            continue
        fi
        TARGET_NUMS+=("$num")
    done
fi

[[ ${#TARGET_NUMS[@]} -eq 0 ]] && { echo "[ERROR] 실행 대상 클러스터가 없습니다."; exit 1; }

# --------------------------------------------------------------
run_on_cluster() {
    local num="$1"
    local log_file="$2"
    local host="${CLUSTER_HOSTS[$num]}" # [변경] $((num-1)) → $num (연관 배열 키 직접 사용)

    {
        echo "===== [클러스터 ${num}] 시작: $(date '+%Y-%m-%d %H:%M:%S') ====="
        echo "  Host : $host"
        echo "  User : $IMPALA_USER"
        echo "  $INPUT_LABEL"
        echo "------------------------------------------------------------"

        impala-shell \
            -i "$host" \
            -u "$IMPALA_USER" \
            --ssl -l \
            --ldap_password_cmd="echo -n $IMPALA_PASS" \
            --auth_creds_ok_in_clear \
            "${INPUT_OPT[@]}"
        local rc=$?

        echo "------------------------------------------------------------"
        [[ $rc -eq 0 ]] \
            && echo "===== [클러스터 ${num}] 완료: $(date '+%Y-%m-%d %H:%M:%S') | 결과: 성공 =====" \
            || echo "===== [클러스터 ${num}] 완료: $(date '+%Y-%m-%d %H:%M:%S') | 결과: 실패 (exit: $rc) ====="
        return $rc
    } > "$log_file" 2>&1
}

# --------------------------------------------------------------
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="${LOG_DIR}/run_${TIMESTAMP}.log"

echo ""
echo "============================================================"
echo " Impala 멀티 클러스터 쿼리 실행기"
echo " 시작  : $(date '+%Y-%m-%d %H:%M:%S')"
printf " 대상  :"; for num in "${TARGET_NUMS[@]}"; do printf "  %d) %s" "$num" "${CLUSTER_HOSTS[$num]}"; done; echo "" # [변경] $((num-1)) → $num
echo " $INPUT_LABEL"
echo " 로그  : $LOG_FILE"
echo "============================================================"
echo ""

declare -a PIDS TMP_FILES

for num in "${TARGET_NUMS[@]}"; do
    tmp_file="${LOG_DIR}/.tmp_cluster${num}_${TIMESTAMP}"
    echo "[START] [${num}] ${CLUSTER_HOSTS[$num]} 실행 시작" # [변경] $((num-1)) → $num
    run_on_cluster "$num" "$tmp_file" &
    PIDS+=($!)
    TMP_FILES+=("$tmp_file")
done

echo ""
echo "[INFO] 전체 클러스터 실행 중... 완료 대기"
echo ""

declare -a SUCCESS FAILED

for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}"; rc=$?
    num="${TARGET_NUMS[$i]}"

    if [[ $rc -eq 0 ]]; then
        SUCCESS+=("$num")
        echo "[  OK  ] [${num}] 성공"
    else
        FAILED+=("$num")
        echo "[ FAIL ] [${num}] 실패"
    fi

    # 클러스터 순서대로 단일 로그에 합치기
    cat "${TMP_FILES[$i]}" >> "$LOG_FILE"
    rm -f "${TMP_FILES[$i]}"
done

echo ""
echo "============================================================"
echo " 실행 결과 요약 | 완료: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
printf " %-6s : %d개  [%s]\n" "성공" "${#SUCCESS[@]}" "${SUCCESS[*]:-없음}"
printf " %-6s : %d개  [%s]\n" "실패" "${#FAILED[@]}" "${FAILED[*]:-없음}"
echo " 로그  : $LOG_FILE"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "------------------------------------------------------------"
    echo " [안내] 아래 클러스터에서 오류가 발생했습니다."
    echo "        로그를 확인 후 해당 클러스터만 재시도하세요."
    echo "------------------------------------------------------------"
    for num in "${FAILED[@]}"; do
        echo ""
        echo "  클러스터 : ${num}) ${CLUSTER_HOSTS[$num]}" # [변경] $((num-1)) → $num
        echo "  재시도   : $SCRIPT_NAME $INPUT_RETRY -c $num"
    done
    echo ""
fi

echo "============================================================"
echo ""

[[ ${#FAILED[@]} -eq 0 ]] && exit 0 || exit 1
