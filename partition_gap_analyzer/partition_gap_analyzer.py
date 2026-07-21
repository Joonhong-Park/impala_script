#!/usr/bin/env python3
"""Impala 파티션 갭 분석 스크립트.

메타스토어에 등록된 최소 파티션 날짜(min_partition_date)와
HDFS 상에 실제 파일로 존재하는 최소 파티션 날짜(min_file_date)의 차이를 계산하여,
메타스토어에 누락된 "고아 데이터"의 갭 일수와 디스크 용량을 출력한다.

단일 테이블 진단:
    python3 partition_gap_analyzer.py db.table_name

여러 테이블 일괄 진단 (결과를 CSV로 저장):
    python3 partition_gap_analyzer.py --list tables.txt --output result.csv
    (tables.txt: 한 줄에 db.table 하나씩, '#'으로 시작하는 줄은 주석으로 무시)
"""

import argparse
import csv
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import List, Optional, Tuple

from impala.dbapi import connect

# ===== 설정 값 (환경에 맞게 수정) =====
IMPALA_HOST = "impala-edge.internal"
IMPALA_PORT = 21050
LDAP_USER = "your_ldap_user"
LDAP_PASSWORD = "your_ldap_password"
SSL_CA_CERT = "/etc/ssl/certs/impala_ca.pem"


@dataclass
class GapResult:
    """갭이 존재하는 경우의 분석 결과."""

    table: str
    min_file_date: date
    gap_end_date: date
    gap_days: int
    gap_bytes: int


def format_gap_size(gap_bytes: int) -> str:
    """콘솔 출력용 갭 용량 포맷 (MB / GB / TB 중 최대 TB까지 자동 전환)."""
    gap_gb = gap_bytes / (1024 ** 3)
    if gap_gb >= 1024:
        return f"{gap_gb / 1024:.2f} TB"
    if gap_gb < 1:
        return f"{gap_gb * 1024:.2f} MB"
    return f"{gap_gb:.2f} GB"


def analyze_table(cursor, table: str) -> Optional[GapResult]:
    """테이블 1개에 대해 파티션 갭을 분석. 갭이 없으면 None 반환."""
    total_steps = 4

    # 1단계: DESCRIBE FORMATTED로 LOCATION과 1단 파티션 컬럼명 추출 (하드코딩 금지, 자동 파싱)
    print(f"  [1/{total_steps}] DESCRIBE FORMATTED 조회 중 (Location/파티션 컬럼 파싱)...")
    cursor.execute(f"DESCRIBE FORMATTED {table}")
    rows = cursor.fetchall()

    location: Optional[str] = None
    partition_col: Optional[str] = None
    in_partition_section = False
    for row in rows:
        col_name = (row[0] or "").strip()
        # Location:은 "# Detailed Table Information" 섹션에 있어
        # "# Partition Information"보다 뒤에 나오므로, 파티션 컬럼을 찾은 뒤에도
        # 루프를 끝까지 돌며 계속 확인해야 한다 (break 금지)
        if col_name.startswith("Location:"):
            location = (row[1] or "").strip()
            continue
        if col_name == "# Partition Information":
            in_partition_section = True
            continue
        if in_partition_section and partition_col is None:
            if col_name == "" or col_name.startswith("#"):
                continue
            partition_col = col_name
            in_partition_section = False  # 1단 파티션 컬럼만 필요하므로 섹션 종료

    if location is None:
        raise RuntimeError(f"'{table}' 테이블의 LOCATION 파싱 실패")
    if partition_col is None:
        raise RuntimeError(f"'{table}' 테이블은 파티션이 없는 테이블입니다 (non-partitioned)")

    # 2단계: SHOW PARTITIONS로 메타스토어 최소 파티션 날짜(min_partition_date) 조회
    print(f"  [2/{total_steps}] SHOW PARTITIONS 조회 중 (min_partition_date 계산)...")
    cursor.execute(f"SHOW PARTITIONS {table}")
    partition_rows = cursor.fetchall()
    partition_col_names = [d[0] for d in cursor.description]
    if partition_col not in partition_col_names:
        raise RuntimeError(f"SHOW PARTITIONS 결과에서 '{partition_col}' 컬럼을 찾을 수 없습니다")
    partition_idx = partition_col_names.index(partition_col)

    partition_dates: List[date] = []
    for row in partition_rows:
        raw_value = str(row[partition_idx]).strip()
        try:
            partition_dates.append(datetime.strptime(raw_value, "%Y-%m-%d").date())
        except ValueError:
            continue  # Total 등 요약 행 스킵

    if not partition_dates:
        raise RuntimeError(f"'{table}' 테이블에 유효한 파티션이 없습니다")

    min_partition_date = min(partition_dates)

    # 3단계: HDFS 디렉토리 스캔 (단일 호출로 끝냄, 재조회 없음)
    print(f"  [3/{total_steps}] HDFS 디렉토리 스캔 중 (hdfs dfs -du -s)...")
    du_result = subprocess.run(
        ["hdfs", "dfs", "-du", "-s", f"{location}/*"],
        capture_output=True,
        text=True,
    )
    if du_result.returncode != 0:
        raise RuntimeError(f"HDFS 조회 실패: {du_result.stderr}")

    file_entries: List[Tuple[int, date]] = []  # (bytes, date)
    for line in du_result.stdout.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        size_bytes_str, path = parts
        match = re.search(rf"{re.escape(partition_col)}=(\d{{4}}-\d{{2}}-\d{{2}})", path)
        if not match:
            print(f"    경고: 날짜 형식이 아닌 디렉토리 스킵 - {path}", file=sys.stderr)
            continue
        dir_date = datetime.strptime(match.group(1), "%Y-%m-%d").date()
        file_entries.append((int(size_bytes_str), dir_date))

    if not file_entries:
        raise RuntimeError("HDFS에서 유효한 파티션 디렉토리를 찾을 수 없습니다")

    min_file_date = min(d for _, d in file_entries)

    # 4단계: 갭 일수/용량 계산 (재조회 없이 메모리 상의 file_entries만 필터링)
    print(f"  [4/{total_steps}] 갭 계산 중...")
    if min_file_date >= min_partition_date:
        return None

    gap_end_date = min_partition_date - timedelta(days=1)
    gap_days = (min_partition_date - min_file_date).days
    gap_bytes = sum(size for size, d in file_entries if min_file_date <= d <= gap_end_date)

    return GapResult(table, min_file_date, gap_end_date, gap_days, gap_bytes)


def print_result(table: str, result: Optional[GapResult]) -> None:
    """단일 테이블 분석 결과를 출력."""
    print(f"테이블명: {table}")
    if result is None:
        print("갭 없음 (min_file_date >= min_partition_date)")
    else:
        print(f"gap날짜 : {result.min_file_date} ~ {result.gap_end_date} ({result.gap_days}일)")
        print(f"gap용량 : {format_gap_size(result.gap_bytes)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Impala 파티션-HDFS 갭 분석")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("table", nargs="?", default=None, help="분석 대상 테이블명 (db.table 형식)")
    group.add_argument("--list", dest="table_list_file", help="테이블 목록 파일 (한 줄에 db.table 하나씩)")
    parser.add_argument(
        "--output", default="partition_gap_result.csv", help="--list 사용 시 CSV 결과 저장 경로"
    )
    args = parser.parse_args()

    conn = connect(
        host=IMPALA_HOST,
        port=IMPALA_PORT,
        auth_mechanism="LDAP",
        user=LDAP_USER,
        password=LDAP_PASSWORD,
        use_ssl=True,
        ca_cert=SSL_CA_CERT,
    )
    cursor = conn.cursor()

    if args.table_list_file:
        with open(args.table_list_file, encoding="utf-8") as f:
            tables = [line.strip() for line in f if line.strip() and not line.strip().startswith("#")]
        if not tables:
            raise RuntimeError(f"'{args.table_list_file}'에 유효한 테이블명이 없습니다")

        total = len(tables)
        csv_rows: List[List[str]] = []
        ok_count = fail_count = no_gap_count = 0
        for i, table in enumerate(tables, 1):
            print(f"[{i}/{total}] {table} 분석 중...")
            try:
                result = analyze_table(cursor, table)
            except Exception as e:
                print(f"  실패: {e}", file=sys.stderr)
                csv_rows.append([table, "", "", "FAIL", str(e)])
                fail_count += 1
                continue
            if result is None:
                print("  갭 없음")
                csv_rows.append([table, "", "", "NO_GAP", ""])
                no_gap_count += 1
                continue
            print(f"  gap날짜 : {result.min_file_date} ~ {result.gap_end_date} ({result.gap_days}일)")
            print(f"  gap용량 : {format_gap_size(result.gap_bytes)}")
            csv_rows.append([table, result.gap_days, result.gap_bytes, "OK", ""])
            ok_count += 1

        with open(args.output, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            # gap_size는 raw bytes로 저장 (단위 변환 없이 정확한 값 보존), status: OK(갭 발견) / NO_GAP / FAIL
            writer.writerow(["table", "gap_day", "gap_size_bytes", "status", "error"])
            writer.writerows(csv_rows)

        print(
            f"완료: 총 {total}개 테이블 중 갭 발견 {ok_count}개, 갭 없음 {no_gap_count}개, "
            f"실패 {fail_count}개, CSV 저장 -> {args.output}"
        )
    else:
        result = analyze_table(cursor, args.table)
        print_result(args.table, result)

    cursor.close()
    conn.close()


if __name__ == "__main__":
    main()
