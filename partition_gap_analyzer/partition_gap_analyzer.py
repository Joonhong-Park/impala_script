#!/usr/bin/env python3
"""Impala 파티션 갭 분석 스크립트.

메타스토어에 등록된 최소 파티션 날짜(min_partition_date)와
HDFS 상에 실제 파일로 존재하는 최소 파티션 날짜(min_file_date)의 차이를 계산하여,
메타스토어에 누락된 "고아 데이터"의 갭 일수와 디스크 용량을 출력한다.
"""

import argparse
import re
import subprocess
import sys
from datetime import date, datetime, timedelta
from typing import List, Optional, Tuple

from impala.dbapi import connect

# ===== 설정 값 (환경에 맞게 수정) =====
IMPALA_HOST = "impala-edge.internal"
IMPALA_PORT = 21050
LDAP_USER = "your_ldap_user"
LDAP_PASSWORD = "your_ldap_password"
SSL_CA_CERT = "/etc/ssl/certs/impala_ca.pem"


def main() -> None:
    parser = argparse.ArgumentParser(description="Impala 파티션-HDFS 갭 분석")
    parser.add_argument("table", help="분석 대상 테이블명 (db.table 형식)")
    args = parser.parse_args()
    table = args.table

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

    # 1. DESCRIBE FORMATTED로 LOCATION과 1단 파티션 컬럼명 추출 (하드코딩 금지, 자동 파싱)
    cursor.execute(f"DESCRIBE FORMATTED {table}")
    rows = cursor.fetchall()

    location: Optional[str] = None
    partition_col: Optional[str] = None
    in_partition_section = False
    for row in rows:
        col_name = (row[0] or "").strip()
        if col_name.startswith("Location:"):
            location = (row[1] or "").strip()
        if col_name == "# Partition Information":
            in_partition_section = True
            continue
        if in_partition_section:
            if col_name == "" or col_name.startswith("#"):
                if partition_col is not None:
                    break
                continue
            partition_col = col_name
            break

    if location is None:
        raise RuntimeError(f"'{table}' 테이블의 LOCATION 파싱 실패")
    if partition_col is None:
        raise RuntimeError(f"'{table}' 테이블은 파티션이 없는 테이블입니다 (non-partitioned)")

    # 2. SHOW PARTITIONS로 메타스토어 최소 파티션 날짜(min_partition_date) 조회
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
    cursor.close()
    conn.close()

    # 3. HDFS 디렉토리 스캔 (단일 호출로 끝냄, 재조회 없음)
    du_result = subprocess.run(
        ["hdfs", "dfs", "-du", "-s", f"{location}/*"],
        capture_output=True,
        text=True,
    )
    if du_result.returncode != 0:
        print(f"HDFS 조회 실패: {du_result.stderr}", file=sys.stderr)
        sys.exit(1)

    file_entries: List[Tuple[int, date]] = []  # (bytes, date)
    for line in du_result.stdout.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        size_bytes_str, path = parts
        match = re.search(rf"{re.escape(partition_col)}=(\d{{4}}-\d{{2}}-\d{{2}})", path)
        if not match:
            print(f"경고: 날짜 형식이 아닌 디렉토리 스킵 - {path}", file=sys.stderr)
            continue
        dir_date = datetime.strptime(match.group(1), "%Y-%m-%d").date()
        file_entries.append((int(size_bytes_str), dir_date))

    if not file_entries:
        raise RuntimeError("HDFS에서 유효한 파티션 디렉토리를 찾을 수 없습니다")

    min_file_date = min(d for _, d in file_entries)

    # 4. 갭 없음 판정
    if min_file_date >= min_partition_date:
        print(f"테이블명: {table}")
        print("갭 없음 (min_file_date >= min_partition_date)")
        return

    gap_end_date = min_partition_date - timedelta(days=1)
    gap_days = (min_partition_date - min_file_date).days

    # 5. 갭 용량 계산 (재조회 없이 메모리 상의 file_entries만 필터링)
    gap_bytes = sum(size for size, d in file_entries if min_file_date <= d <= gap_end_date)
    gap_gb = gap_bytes / (1024 ** 3)
    if gap_gb < 1:
        gap_size_str = f"{gap_bytes / (1024 ** 2):.2f} MB"
    else:
        gap_size_str = f"{gap_gb:.2f} GB"

    # 6. 출력
    print(f"테이블명: {table}")
    print(f"gap날짜 : {min_file_date} ~ {gap_end_date} ({gap_days}일)")
    print(f"gap용량 : {gap_size_str}")


if __name__ == "__main__":
    main()
