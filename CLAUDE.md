# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`impala_query_executor.sh` — 5개의 Impala 클러스터에 동시에 쿼리를 실행하는 bash 스크립트. LDAP 인증 + SSL로 impala-shell에 접속하며, 클러스터별 병렬 실행 후 전체 결과를 단일 로그 파일로 저장한다.

## 실행 방법

```bash
# 쿼리 직접 입력 (전체 클러스터)
./impala_query_executor.sh -q "SELECT count(*) FROM db.table"

# SQL 파일 실행 (전체 클러스터)
./impala_query_executor.sh -f ./add_partition.sql

# 특정 클러스터만 선택 (번호 사용, 1~5)
./impala_query_executor.sh -q "REFRESH db.table" -c 1,3
./impala_query_executor.sh -f ./create_table.sql -c 2,4,5

# 문법 검사
bash -n impala_query_executor.sh
```

## 클러스터 접속 정보 수정

스크립트 상단 `CLUSTER_HOSTS` **연관 배열**에 번호를 키로 호스트를 관리한다. 번호가 키에 직접 대응하므로 특정 항목을 주석 처리해도 나머지 번호가 당겨지지 않는다.

```bash
declare -A CLUSTER_HOSTS
CLUSTER_HOSTS[1]="host1.example.com"
# CLUSTER_HOSTS[2]="host2.example.com"  # 주석 처리해도 3~5번 번호 유지
CLUSTER_HOSTS[3]="host3.example.com"
CLUSTER_HOSTS[4]="host4.example.com"
CLUSTER_HOSTS[5]="host5.example.com"
IMPALA_USER="impala"
IMPALA_PASS="passwd"
```

클러스터 추가/삭제 시 `CLUSTER_HOSTS` 배열 한 곳만 수정하면 된다. 주석 처리된 번호를 `-c`로 지정하면 경고 후 건너뜀.

## 아키텍처

- **병렬 실행**: `run_on_cluster`를 `&`로 백그라운드 실행 → PID 수집 → `wait`로 전체 완료 대기
- **로그**: 클러스터별 임시 파일(`.tmp_cluster{N}`)로 병렬 기록 → 완료 순서대로 `logs/run_{YYYYMMDD_HHMMSS}.log` 단일 파일로 합산 후 임시 파일 삭제
- **클러스터 번호**: `-c` 옵션에 번호 사용, `CLUSTER_HOSTS` 연관 배열 키 기준 — 항목 주석 처리 시에도 번호 고정
- **종료 코드**: 하나라도 실패하면 exit 1, 전부 성공하면 exit 0
- **SQL 파일 실행**: impala-shell `-f` 옵션으로 파일 전체를 단일 연결로 실행

## 주로 사용하는 쿼리 패턴

```sql
ALTER TABLE db.table ADD IF NOT EXISTS PARTITION (dt='YYYY-MM-DD');
REFRESH db.table;
RECOVER PARTITIONS db.table;
DROP TABLE IF EXISTS db.table;
CREATE TABLE db.table (...) PARTITIONED BY (...);
SELECT count(*) FROM db.table;
```
