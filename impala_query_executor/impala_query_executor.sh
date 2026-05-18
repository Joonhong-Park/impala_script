#!/bin/bash

# ==============================================================
# 멀티 클러스터 Impala 쿼리 실행기
# 사용법: ./impala_query_executor.sh -q "쿼리문" | -f sql파일 [-c 번호(쉼표구분)]
# ==============================================================

ALL_CLUSTERS=("cluster1" "cluster2" "cluster3" "cluster4" "cluster5")

IMPALA_USER="impala"
IMPALA_PASS="passwd"

declare -A CLUSTER_HOST

CLUSTER_HOST["cluster1"]="host1.example.com"
CLUSTER_HOST["cluster2"]="host2.example.com"
CLUSTER_HOST["cluster3"]="host3.example.com"
CLUSTER_HOST["cluster4"]="host4.example.com"
CLUSTER_HOST["cluster5"]="host5.example.com"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

MAX_NUM=${#ALL_CLUSTERS[@]}

usage() {
    cat <<EOF

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -q <query>    실행할 쿼리문 (직접 입력)
  -f <file>     실행할 SQL 파일 경로
  -c <numbers>  대상 클러스터 번호 - 쉼표 구분, 1~${MAX_NUM} (기본값: 전체)
  -h            도움말

Clusters:
$(for i in "${!ALL_CLUSTERS[@]}"; do printf "  %d) %s\n" $((i+1)) "${CLUSTER_HOST[${ALL_CLUSTERS[$i]}]}"; done)

Examples:
  $SCRIPT_NAME -q "SELECT count(*) FROM db.table_name"
  $SCRIPT_NAME -f ./sql/add_partition.sql
  $SCRIPT_NAME -q "REFRESH db.table_name" -c 1,3
  $SCRIPT_NAME -f ./sql/create_table.sql -c 2,4,5

EOF
    exit 1
}

QUERY=""
SQL_FILE=""
TARGET_INPUT=""

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

if [[ -z "$QUERY" && -z "$SQL_FILE" ]]; then
    echo "[ERROR] -q 또는 -f 옵션 중 하나는 필수입니다."
    usage
fi

if [[ -n "$QUERY" && -n "$SQL_FILE" ]]; then
    echo "[ERROR] -q 와 -f 는 동시에 사용할 수 없습니다."
    usage
fi

if [[ -n "$SQL_FILE" ]]; then
    SQL_FILE="$(realpath "$SQL_FILE" 2>/dev/null || echo "$SQL_FILE")"
    if [[ ! -f "$SQL_FILE" ]]; then
        echo "[ERROR] SQL 파일을 찾을 수 없습니다: $SQL_FILE"
        exit 1
    fi
fi

if [[ -n "$QUERY" ]]; then
    INPUT_OPT=(-q "$QUERY")
    INPUT_LABEL="쿼리  : $QUERY"
    INPUT_RETRY="-q \"$QUERY\""
else
    INPUT_OPT=(-f "$SQL_FILE")
    INPUT_LABEL="파일  : $SQL_FILE"
    INPUT_RETRY="-f $SQL_FILE"
fi

TARGET_LIST=()
TARGET_NUMS=()

if [[ -z "$TARGET_INPUT" ]]; then
    TARGET_LIST=("${ALL_CLUSTERS[@]}")
    for i in "${!ALL_CLUSTERS[@]}"; do TARGET_NUMS+=($((i+1))); done
else
    IFS=',' read -ra selected <<< "$TARGET_INPUT"
    for num in "${selected[@]}"; do
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [[ $num -lt 1 ]] || [[ $num -gt $MAX_NUM ]]; then
            echo "[WARN] 유효하지 않은 번호: '$num' (건너뜀, 1~${MAX_NUM} 사이)"
            continue
        fi
        TARGET_LIST+=("${ALL_CLUSTERS[$((num-1))]}")
        TARGET_NUMS+=("$num")
    done
fi

if [[ ${#TARGET_LIST[@]} -eq 0 ]]; then
    echo "[ERROR] 실행 대상 클러스터가 없습니다."
    exit 1
fi

run_on_cluster() {
    local cluster="$1"
    local log_file="$2"

    local host="${CLUSTER_HOST[$cluster]}"

    {
        echo "===== [$cluster] 시작: $(date '+%Y-%m-%d %H:%M:%S') ====="
        echo "  Host : $host"
        echo "  User : $IMPALA_USER"
        echo "  $INPUT_LABEL"
        echo "------------------------------------------------------------"

        impala-shell \
            -i "$host" \
            -u "$IMPALA_USER" \
            --ssl \
            -l \
            --ldap_password_cmd="echo -n $IMPALA_PASS" \
            --auth_creds_ok_in_clear \
            "${INPUT_OPT[@]}"
        local rc=$?

        echo "------------------------------------------------------------"
        if [[ $rc -eq 0 ]]; then
            echo "===== [$cluster] 완료: $(date '+%Y-%m-%d %H:%M:%S') | 결과: 성공 ====="
        else
            echo "===== [$cluster] 완료: $(date '+%Y-%m-%d %H:%M:%S') | 결과: 실패 (exit: $rc) ====="
        fi

        return $rc
    } > "$log_file" 2>&1
}

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "============================================================"
echo " Impala 멀티 클러스터 쿼리 실행기"
echo " 시작  : $START_TIME"
printf " 대상  :"; for i in "${!TARGET_LIST[@]}"; do printf "  %s) %s" "${TARGET_NUMS[$i]}" "${TARGET_LIST[$i]}"; done; echo ""
echo " $INPUT_LABEL"
echo " 로그  : $LOG_DIR (실패 클러스터만 보관)"
echo "============================================================"
echo ""

declare -a PIDS LOG_FILES

for i in "${!TARGET_LIST[@]}"; do
    cluster="${TARGET_LIST[$i]}"
    num="${TARGET_NUMS[$i]}"
    log_file="${LOG_DIR}/${cluster}_${TIMESTAMP}.log"
    echo "[START] [${num}] $cluster 실행 시작 → $(basename "$log_file")"
    run_on_cluster "$cluster" "$log_file" &
    PIDS+=($!)
    LOG_FILES+=("$log_file")
done

echo ""
echo "[INFO] 전체 클러스터 실행 중... 완료 대기"
echo ""

declare -a SUCCESS FAILED FAILED_LOGS FAILED_NUMS

for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}"
    rc=$?
    cluster="${TARGET_LIST[$i]}"
    num="${TARGET_NUMS[$i]}"
    log="${LOG_FILES[$i]}"

    if [[ $rc -eq 0 ]]; then
        SUCCESS+=("${num}) ${cluster}")
        rm -f "$log"
        echo "[  OK  ] [${num}] $cluster 성공"
    else
        FAILED+=("${num}) ${cluster}")
        FAILED_LOGS+=("$log")
        FAILED_NUMS+=("$num")
        echo "[ FAIL ] [${num}] $cluster 실패 → $(basename "$log")"
    fi
done

echo ""
echo "============================================================"
echo " 실행 결과 요약 | 완료: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
printf " %-6s : %d개  [%s]\n" "성공" "${#SUCCESS[@]}" "${SUCCESS[*]:-없음}"
printf " %-6s : %d개  [%s]\n" "실패" "${#FAILED[@]}" "${FAILED[*]:-없음}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "------------------------------------------------------------"
    echo " [안내] 아래 클러스터에서 오류가 발생했습니다."
    echo "        로그를 확인 후 해당 클러스터만 재시도하세요."
    echo "------------------------------------------------------------"

    for i in "${!FAILED[@]}"; do
        echo ""
        echo "  클러스터 : ${FAILED[$i]}"
        echo "  로그파일 : ${FAILED_LOGS[$i]}"
        echo "  재시도   : $SCRIPT_NAME $INPUT_RETRY -c ${FAILED_NUMS[$i]}"
    done
    echo ""
fi

echo "============================================================"
echo ""

[[ ${#FAILED[@]} -eq 0 ]] && exit 0 || exit 1
