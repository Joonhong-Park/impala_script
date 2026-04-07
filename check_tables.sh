#!/usr/bin/env bash
# =============================================================================
# Impala Table Health Checker (Shell version)
# Usage: ./check_tables.sh [table_file] [--workers N]
# =============================================================================

set -euo pipefail

# ── 클러스터 설정 (실제 호스트로 변경) ────────────────────────────────────────
CLUSTER_NAMES=("Cluster-A"             "Cluster-B"             "Cluster-C"             "Cluster-D")
CLUSTER_HOSTS=("impala-a.example.com"  "impala-b.example.com"  "impala-c.example.com"  "impala-d.example.com")
CLUSTER_PORT=21050

# ── 인자 파싱 ─────────────────────────────────────────────────────────────────
TABLE_FILE="tables.txt"
MAX_WORKERS=8

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers) MAX_WORKERS="$2"; shift 2 ;;
        --output)  shift 2 ;;   # (사용 안 함)
        -*)        echo "Unknown option: $1" >&2; exit 1 ;;
        *)         TABLE_FILE="$1";  shift ;;
    esac
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── 테이블 목록 읽기 ──────────────────────────────────────────────────────────
if [[ ! -f "$TABLE_FILE" ]]; then
    echo "[ERROR] 파일을 찾을 수 없습니다: $TABLE_FILE" >&2
    exit 1
fi

mapfile -t TABLES < <(grep -v '^\s*#' "$TABLE_FILE" | grep -v '^\s*$' | sed 's/\s//g')

if [[ ${#TABLES[@]} -eq 0 ]]; then
    echo "[ERROR] 테이블 목록이 비어있습니다." >&2
    exit 1
fi

NUM_CLUSTERS=${#CLUSTER_NAMES[@]}
NUM_TABLES=${#TABLES[@]}
TOTAL=$(( NUM_CLUSTERS * NUM_TABLES ))

echo "============================================================"
echo " Impala Table Health Checker"
echo " 클러스터: ${NUM_CLUSTERS}개  |  테이블: ${NUM_TABLES}개  |  총 쿼리: ${TOTAL}개"
echo " 시작: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ── 에러 키 추출 함수 ─────────────────────────────────────────────────────────
extract_error_key() {
    local msg="$1"
    local patterns=(
        "BlockMissingException"
        "TableLoadingException"
        "TableNotFoundException"
        "AnalysisException"
        "AuthorizationException"
        "ImpalaRuntimeException"
        "DatabaseNotFoundException"
        "FileNotFoundException"
        "HdfsIOException"
    )
    for p in "${patterns[@]}"; do
        if echo "$msg" | grep -qi "$p"; then
            echo "$p"; return
        fi
    done
    if echo "$msg" | grep -qi "connection refused";  then echo "ConnectionRefused"; return; fi
    if echo "$msg" | grep -qi "timed.*out\|timeout"; then echo "Timeout";           return; fi
    if echo "$msg" | grep -qi "permission denied";   then echo "PermissionDenied";  return; fi
    # fallback: 첫 번째 줄 60자
    echo "$msg" | grep -v '^\s*$' | head -1 | cut -c1-60
}

# ── 단일 테이블 체크 ──────────────────────────────────────────────────────────
# 결과를 $TMP_DIR/<cluster_idx>_<table_idx> 파일에 저장
# 파일 내용: PASS 또는 FAIL\t<error_key>
check_one() {
    local cidx="$1"   # 클러스터 인덱스
    local tidx="$2"   # 테이블 인덱스
    local host="${CLUSTER_HOSTS[$cidx]}"
    local table="${TABLES[$tidx]}"
    local out="$TMP_DIR/${cidx}_${tidx}"

    local impala_out
    impala_out=$(
        impala-shell \
            -i "${host}:${CLUSTER_PORT}" \
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
}

# ── 병렬 실행 ─────────────────────────────────────────────────────────────────
DONE=0
ACTIVE=0
declare -A PID_MAP   # pid -> "cidx tidx"

run_with_limit() {
    # 활성 job 수가 MAX_WORKERS 이상이면 하나 완료될 때까지 대기
    while [[ $ACTIVE -ge $MAX_WORKERS ]]; do
        for pid in "${!PID_MAP[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null || true
                unset PID_MAP[$pid]
                (( ACTIVE-- ))
                (( DONE++ ))
            fi
        done
        sleep 0.05
    done
}

echo ""
for cidx in "${!CLUSTER_NAMES[@]}"; do
    for tidx in "${!TABLES[@]}"; do
        run_with_limit
        check_one "$cidx" "$tidx" &
        pid=$!
        PID_MAP[$pid]="${cidx} ${tidx}"
        (( ACTIVE++ ))
        printf "\r  진행: %d / %d ..." "$DONE" "$TOTAL"
    done
done

# 나머지 대기
for pid in "${!PID_MAP[@]}"; do
    wait "$pid" 2>/dev/null || true
    (( DONE++ ))
    printf "\r  진행: %d / %d ..." "$DONE" "$TOTAL"
done
echo ""
echo ""

# ── 결과 읽기 ─────────────────────────────────────────────────────────────────
# matrix[cidx][tidx] = "PASS" or "FAIL\t<errkey>"
declare -A MATRIX
for cidx in "${!CLUSTER_NAMES[@]}"; do
    for tidx in "${!TABLES[@]}"; do
        f="$TMP_DIR/${cidx}_${tidx}"
        if [[ -f "$f" ]]; then
            MATRIX["${cidx}_${tidx}"]=$(cat "$f")
        else
            MATRIX["${cidx}_${tidx}"]="N/A"
        fi
    done
done

# ── 컬럼 너비 계산 ────────────────────────────────────────────────────────────
COL_W=32
NAME_W=14

pad_right() { printf "%-${2}s" "$1"; }
pad_left()  { printf "%${2}s"  "$1"; }

# ── 콘솔 테이블 출력 ──────────────────────────────────────────────────────────
SEP_LINE=$(printf '%0.s─' $(seq 1 $(( NAME_W + 2 + (COL_W + 2) * NUM_TABLES + 14 ))))

echo "$SEP_LINE"

# 헤더
printf "  %-${NAME_W}s" "Cluster \\ Table"
for tidx in "${!TABLES[@]}"; do
    t="${TABLES[$tidx]}"
    # 테이블명이 길면 마지막 N글자만 표시
    label="${t: -$((COL_W-2))}"
    printf "  %-${COL_W}s" "$label"
done
printf "  %s\n" "PASS/TOTAL"

echo "$SEP_LINE"

declare -A COL_PASS COL_TOTAL
for tidx in "${!TABLES[@]}"; do
    COL_PASS[$tidx]=0
    COL_TOTAL[$tidx]=0
done

GRAND_PASS=0
GRAND_TOTAL=0

for cidx in "${!CLUSTER_NAMES[@]}"; do
    row_pass=0
    row_total=0
    printf "  %-${NAME_W}s" "${CLUSTER_NAMES[$cidx]}"
    for tidx in "${!TABLES[@]}"; do
        val="${MATRIX["${cidx}_${tidx}"]}"
        st=$(echo "$val" | cut -f1)
        err=$(echo "$val" | cut -f2- -s)

        (( COL_TOTAL[$tidx]++ ))
        (( row_total++ ))

        if [[ "$st" == "PASS" ]]; then
            (( COL_PASS[$tidx]++ ))
            (( row_pass++ ))
            cell="PASS"
        elif [[ "$st" == "FAIL" ]]; then
            cell="FAIL(${err})"
        else
            cell="$st"
        fi
        # 셀 너비 초과 시 자름
        cell="${cell:0:$COL_W}"
        printf "  %-${COL_W}s" "$cell"
    done
    (( GRAND_PASS  += row_pass  ))
    (( GRAND_TOTAL += row_total ))
    printf "  %s/%s\n" "$row_pass" "$row_total"
done

echo "$SEP_LINE"

# 열 합계
printf "  %-${NAME_W}s" "PASS/TOTAL"
for tidx in "${!TABLES[@]}"; do
    printf "  %-${COL_W}s" "${COL_PASS[$tidx]}/${COL_TOTAL[$tidx]}"
done
printf "  %s/%s\n" "$GRAND_PASS" "$GRAND_TOTAL"
echo "$SEP_LINE"
echo ""
echo "  전체: ${GRAND_PASS}/${GRAND_TOTAL} PASS  |  $(( GRAND_TOTAL - GRAND_PASS ))/${GRAND_TOTAL} FAIL"
echo "  완료: $(date '+%Y-%m-%d %H:%M:%S')"

# ── 클러스터별 FAIL 테이블 summary ───────────────────────────────────────────
echo ""
echo "============================================================"
echo " FAIL Summary (클러스터별)"
echo "============================================================"

for cidx in "${!CLUSTER_NAMES[@]}"; do
    fail_list=()
    for tidx in "${!TABLES[@]}"; do
        val="${MATRIX["${cidx}_${tidx}"]}"
        st=$(echo "$val" | cut -f1)
        err=$(echo "$val" | cut -f2- -s)
        if [[ "$st" == "FAIL" ]]; then
            fail_list+=("  - ${TABLES[$tidx]}  (${err})")
        fi
    done

    fail_count=${#fail_list[@]}
    echo ""
    echo "  [${CLUSTER_NAMES[$cidx]}]  FAIL: ${fail_count}개"
    if [[ $fail_count -eq 0 ]]; then
        echo "    (없음)"
    else
        for line in "${fail_list[@]}"; do
            echo "$line"
        done
    fi
done

echo ""
echo "============================================================"
echo ""
