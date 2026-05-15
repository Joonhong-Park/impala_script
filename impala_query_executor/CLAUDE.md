# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`run_query.sh` — 5개의 Impala 클러스터에 동시에 쿼리를 실행하는 bash 스크립트. LDAP 인증 + SSL로 impala-shell에 접속하며, 클러스터별로 병렬 실행 후 결과를 로그 파일에 저장한다.

## 실행 방법

```bash
# 쿼리 직접 입력 (전체 클러스터)
./impala_query_executor.sh -q "SELECT count(*) FROM db.table_name"

# SQL 파일 실행 (전체 클러스터)
./impala_query_executor.sh -f ./sql/add_partition.sql

# 특정 클러스터만 선택 (-c 에 번호 사용, 1~5)
./impala_query_executor.sh -q "REFRESH db.table_name" -c 1,3
./impala_query_executor.sh -f ./sql/create_table.sql -c 2,4,5

# 문법 검사
bash -n impala_query_executor.sh
```

## 클러스터 접속 정보 수정

스크립트 상단 세 개의 연관 배열(`CLUSTER_HOST`, `CLUSTER_USER`, `CLUSTER_PASS`)과 `ALL_CLUSTERS` 순서 배열을 함께 수정한다. 클러스터 추가/삭제 시 두 곳 모두 반영해야 한다.

## 아키텍처

- **병렬 실행**: `run_on_cluster`를 `&`로 백그라운드 실행 → PID 수집 → `wait`로 전체 완료 대기
- **로그**: `logs/{cluster}_{YYYYMMDD_HHMMSS}.log` — 실패한 클러스터만 보관, 성공 시 자동 삭제
- **클러스터 순서**: `-c` 옵션으로 지정해도 실행 순서는 항상 `ALL_CLUSTERS` 배열 기준으로 정렬됨
- **종료 코드**: 하나라도 실패하면 exit 1, 전부 성공하면 exit 0
- **SQL 파일 실행**: impala-shell `-f` 옵션으로 파일 전체를 단일 연결로 실행 (구문별 분리 없음)

## SQL 파일

`sql/` 디렉토리에 `.sql` 파일로 보관. 주로 사용하는 쿼리 패턴:

```sql
-- 파티션 추가
ALTER TABLE db.table_name ADD IF NOT EXISTS PARTITION (dt='YYYY-MM-DD');

-- 자주 쓰는 DDL/메타데이터 갱신
REFRESH db.table_name;
RECOVER PARTITIONS db.table_name;
DROP TABLE IF EXISTS db.table_name;
CREATE TABLE db.table_name (...) PARTITIONED BY (...);
```

SQL 파일 하나에 여러 구문을 세미콜론으로 구분해서 작성하면 `-f` 옵션으로 순차 실행된다.
