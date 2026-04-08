#!/usr/bin/env bash

# ── 설정 ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CLUSTER_NAMES=("Cluster-A"            "Cluster-B"            "Cluster-C"            "Cluster-D")
CLUSTER_HOSTS=("impala-a.example.com" "impala-b.example.com" "impala-c.example.com" "impala-d.example.com")
CLUSTER_PORT=21050

LDAP_USER="impala_user"
LDAP_PASS="impala_pass"

TABLE_FILE="${SCRIPT_DIR}/tables.txt"
LOG_FILE="${SCRIPT_DIR}/result_$(date +%Y%m%d_%H%M%S).log"
WORK_DIR="${SCRIPT_DIR}/.work_$$"

# ── 에러 키 추출 ───────────────────────────────────────────────────────────────
extract_error_key() {
    local msg="$1"
    local exception
    exception=$(echo "$msg" | grep -oiE '[A-Za-z]+Exception' | head -1)
    if [[ -n "$exception" ]]; then
        echo "$exception"; return
    fi
    # fallback: 첫 번째 비어있지 않은 줄 60자
    echo "$msg" | grep -v '^\s*$' | head -1 | cut -c1-60
}

# ── 클러스터별 순차 조회 ────────────────────────────────────────────────────────
# 결과 파일: $WORK_DIR/<cidx>_<tidx>
# 내용: PASS 또는 FAIL\t<error_key>
run_cluster() {
    local cidx="$1"
    local host="${CLUSTER_HOSTS[$cidx]}"

    for tidx in "${!TABLES[@]}"; do
        local table="${TABLES[$tidx]}"
        local out="${WORK_DIR}/${cidx}_${tidx}"

        local impala_out
        impala_out=$(
            impala-shell \
                -i "${host}:${CLUSTER_PORT}" \
                -l \
                --user="${LDAP_USER}" \
                --ldap_password_cmd="echo -n ${LDAP_PASS}" \
                --ssl \
                -q "SELECT 1 FROM ${table} LIMIT 1" \
                2>&1
        ) && rc=0 || rc=$?

        if [[ $rc -eq 0 ]] && ! echo "$impala_out" | grep -qi "ERROR\|FAILED"; then
            echo "PASS" > "$out"
        else
            local errkey
            errkey=$(extract_error_key "$impala_out")
            printf "FAIL\t%s" "$errkey" > "$out"
        fi
    done
}

# ── 실행 ──────────────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# 테이블 목록 읽기
if [[ ! -f "$TABLE_FILE" ]]; then
    echo "[ERROR] 파일을 찾을 수 없습니다: $TABLE_FILE" >&2; exit 1
fi
mapfile -t TABLES < <(grep -v '^\s*#' "$TABLE_FILE" | grep -v '^\s*$' | sed 's/\s//g')
if [[ ${#TABLES[@]} -eq 0 ]]; then
    echo "[ERROR] 테이블 목록이 비어있습니다." >&2; exit 1
fi

NUM_CLUSTERS=${#CLUSTER_NAMES[@]}
NUM_TABLES=${#TABLES[@]}

echo "======================================================"
echo " Impala Table Health Checker"
echo " 클러스터: ${NUM_CLUSTERS}개  |  테이블: ${NUM_TABLES}개"
echo " 시작: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================"

# 클러스터별 백그라운드 실행
declare -a CLUSTER_PIDS
for cidx in "${!CLUSTER_NAMES[@]}"; do
    run_cluster "$cidx" &
    CLUSTER_PIDS[$cidx]=$!
done

# 완료 대기 및 진행 상황 출력
while true; do
    done_count=0
    for cidx in "${!CLUSTER_NAMES[@]}"; do
        if ! kill -0 "${CLUSTER_PIDS[$cidx]}" 2>/dev/null; then
            (( done_count++ ))
        fi
    done
    checked=$(ls "$WORK_DIR" 2>/dev/null | wc -l)
    printf "\r  진행: %d / %d ..." "$checked" "$(( NUM_CLUSTERS * NUM_TABLES ))"
    [[ $done_count -eq $NUM_CLUSTERS ]] && break
    sleep 1
done

for cidx in "${!CLUSTER_NAMES[@]}"; do
    wait "${CLUSTER_PIDS[$cidx]}"
done
echo ""

# ── 결과 수집 ──────────────────────────────────────────────────────────────────
declare -A MATRIX
for cidx in "${!CLUSTER_NAMES[@]}"; do
    for tidx in "${!TABLES[@]}"; do
        f="${WORK_DIR}/${cidx}_${tidx}"
        if [[ -f "$f" ]]; then
            MATRIX["${cidx}_${tidx}"]=$(cat "$f")
        else
            MATRIX["${cidx}_${tidx}"]="N/A"
        fi
    done
done

# ── 표 출력 ────────────────────────────────────────────────────────────────────
COL_W=10
NAME_W=32
EXC_W=60
SEP=$(printf '%0.s─' $(seq 1 $(( NAME_W + 2 + (COL_W + 2) * NUM_CLUSTERS + EXC_W + 4 ))))

declare -A COL_PASS COL_TOTAL
for cidx in "${!CLUSTER_NAMES[@]}"; do COL_PASS[$cidx]=0; COL_TOTAL[$cidx]=0; done
GRAND_PASS=0; GRAND_TOTAL=0

{
    echo "$SEP"
    # 헤더
    printf "  %-${NAME_W}s" "Table"
    for cidx in "${!CLUSTER_NAMES[@]}"; do
        printf "  %-${COL_W}s" "${CLUSTER_NAMES[$cidx]}"
    done
    printf "  %-${EXC_W}s\n" "Exception"
    echo "$SEP"

    # 데이터 행
    for tidx in "${!TABLES[@]}"; do
        printf "  %-${NAME_W}s" "${TABLES[$tidx]}"
        exc_parts=()
        row_pass=0; row_total=0
        for cidx in "${!CLUSTER_NAMES[@]}"; do
            val="${MATRIX["${cidx}_${tidx}"]}"
            st=$(echo "$val" | cut -f1)
            err=$(echo "$val" | cut -f2- -s)
            (( COL_TOTAL[$cidx]++ )); (( row_total++ ))
            if [[ "$st" == "PASS" ]]; then
                (( COL_PASS[$cidx]++ )); (( row_pass++ ))
                printf "  %-${COL_W}s" "O"
            elif [[ "$st" == "FAIL" ]]; then
                printf "  %-${COL_W}s" "X"
                [[ -n "$err" ]] && exc_parts+=("${CLUSTER_NAMES[$cidx]}:${err}")
            else
                printf "  %-${COL_W}s" "-"
            fi
        done
        (( GRAND_PASS += row_pass )); (( GRAND_TOTAL += row_total ))
        exc_str=$(IFS=', '; echo "${exc_parts[*]}")
        printf "  %-${EXC_W}s\n" "${exc_str:0:$EXC_W}"
    done

    echo "$SEP"
    # 열 합계
    printf "  %-${NAME_W}s" "PASS/TOTAL"
    for cidx in "${!CLUSTER_NAMES[@]}"; do
        printf "  %-${COL_W}s" "${COL_PASS[$cidx]}/${COL_TOTAL[$cidx]}"
    done
    printf "  %-${EXC_W}s\n" ""
    echo "$SEP"

} | tee -a "$LOG_FILE"

# ── 클러스터별 FAIL Summary ────────────────────────────────────────────────────
{
    echo ""
    echo "======================================================"
    echo " FAIL Summary (클러스터별)"
    echo "======================================================"

    for cidx in "${!CLUSTER_NAMES[@]}"; do
        fail_list=()
        for tidx in "${!TABLES[@]}"; do
            val="${MATRIX["${cidx}_${tidx}"]}"
            st=$(echo "$val" | cut -f1)
            err=$(echo "$val" | cut -f2- -s)
            if [[ "$st" == "FAIL" ]]; then
                fail_list+=("    - ${TABLES[$tidx]}  (${err})")
            fi
        done

        echo ""
        echo "  [${CLUSTER_NAMES[$cidx]}]  FAIL: ${#fail_list[@]}개"
        if [[ ${#fail_list[@]} -eq 0 ]]; then
            echo "    (없음)"
        else
            for line in "${fail_list[@]}"; do
                echo "$line"
            done
        fi
    done

    echo ""
    echo "======================================================"
    echo " 전체: ${GRAND_PASS}/${GRAND_TOTAL} PASS  |  $(( GRAND_TOTAL - GRAND_PASS ))/${GRAND_TOTAL} FAIL"
    echo " 완료: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "======================================================"

} | tee -a "$LOG_FILE"
