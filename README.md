# impala_script

## 프로젝트 목록

| 디렉토리 | 설명 |
|----------|------|
| [impala_query_executor](./impala_query_executor) | 멀티 클러스터 Impala 쿼리 동시 실행기 |
| [partition_gap_analyzer](./partition_gap_analyzer) | Impala 메타스토어 파티션과 HDFS 실제 파일 간의 갭(고아 데이터) 탐지 스크립트 |

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

---

## partition_gap_analyzer

Impala External Table의 메타스토어 파티션 정보와 실제 HDFS 파일 시스템 상태 간의
불일치(갭)를 탐지하는 단발성 진단 스크립트. 상세 설계는 [CLAUDE.md](./partition_gap_analyzer/CLAUDE.md) 참고.

### 사용법

```bash
python3 partition_gap_analyzer.py db.table_name
```

### 특징

- `DESCRIBE FORMATTED` / `SHOW PARTITIONS`로 메타스토어의 최소 파티션 날짜(`min_partition_date`) 조회
- `hdfs dfs -du -s` 단 한 번의 호출로 HDFS 실제 파일의 최소 파티션 날짜(`min_file_date`)와 용량을 함께 확보 (재조회 없음)
- 갭 일수 및 갭 용량(GB/MB 자동 단위 전환)을 계산하여 출력
