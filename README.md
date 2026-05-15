# impala_script

## 프로젝트 목록

| 디렉토리 | 설명 |
|----------|------|
| [impala_query_executor](./impala_query_executor) | 멀티 클러스터 Impala 쿼리 동시 실행기 |

---

## impala_query_executor

5개의 Impala 클러스터에 쿼리를 병렬로 실행하는 bash 스크립트.

### 사용법

```bash
# 쿼리 직접 입력 (전체 클러스터)
./impala_query_executor.sh -q "SELECT count(*) FROM db.table_name"

# SQL 파일 실행 (전체 클러스터)
./impala_query_executor.sh -f ./sql/add_partition.sql

# 특정 클러스터만 선택 (번호 사용, 1~5)
./impala_query_executor.sh -q "REFRESH db.table_name" -c 1,3
./impala_query_executor.sh -f ./sql/create_table.sql -c 2,4,5
```

### 특징

- 클러스터별 병렬 실행 후 전체 완료 대기
- 실패한 클러스터만 로그 파일 보관 (`logs/`)
- 실패 시 재시도 명령어 자동 안내
