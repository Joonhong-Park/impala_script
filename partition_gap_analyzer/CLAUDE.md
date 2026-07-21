# partition_gap_analyzer

## 목적

Impala External Table의 **메타스토어 파티션 정보**와 **실제 HDFS 파일 시스템 상태** 간의
불일치(갭)를 탐지하는 단발성 진단 스크립트.

구체적으로, 다음 두 값의 차이를 계산한다:

- `min_partition_date`: `SHOW PARTITIONS`로 조회한, **메타스토어에 등록된** 1단 파티션(Date) 중 최소 날짜
- `min_file_date`: 실제 HDFS Location 하위에 **파일로 존재하는** 1단 파티션 디렉토리 중 최소 날짜

두 값의 차이가 발생하는 경우는, HDFS에는 과거 데이터가 남아 있지만 Impala 메타스토어에는
해당 파티션이 등록(`ALTER TABLE ... ADD PARTITION` 또는 `MSCK REPAIR`)되지 않아
**조회 시 누락되는 "고아 데이터"**가 존재함을 의미한다. 이 스크립트는 그 갭 기간의
일수와 실제 디스크 용량(GB)을 계산하여, 데이터 정합성 점검 및 스토리지 회수/재등록
의사결정에 활용한다.

## 배경 (플랫폼 컨텍스트)

- Cloudera CDP 5클러스터 (vmc1~vmc5), Air-gap 환경
- Impala: External Table + View 구조, 파티션 없음~최대 2개
  - 1st 파티션: Date 타입 (`yyyy-MM-dd`)
  - 2nd 파티션: String 타입 (optional)
- 데이터는 별도 HDFS 서버에 Parquet 포맷으로 저장, Spark 또는 NiFi(vanilla)로 수집
- Impala 인증: LDAP + SSL (Kerberos 미사용)
- 스크립트는 **엣지노드에서 직접 실행** (hdfs CLI 사용 가능 환경)

## 핵심 로직

### 1. Impala 메타정보 조회 (impyla)

```
DESCRIBE FORMATTED {table}
```
- `Location:` 라인 파싱 → HDFS 경로 추출
- `# Partition Information` 섹션 파싱 → 1단 파티션 컬럼명 추출 (자동 추출, 하드코딩 금지)

```
SHOW PARTITIONS {table}
```
- 1단 파티션 값들 중 최소 날짜 → `min_partition_date`

### 2. HDFS 디렉토리 스캔 (hdfs CLI, subprocess)

```bash
hdfs dfs -du -s {location}/*
```

- **HDFS 접근은 이 한 번의 호출로 끝낸다.** 재조회 없음 (속도 최적화 핵심 요구사항)
- `-du -s`는 지정 경로 각각에 대해 하위 전체를 재귀 합산한 총 용량을 반환하므로,
  2단 String 파티션이 있어도 1단 디렉토리 레벨의 `-du -s` 결과에 자동으로 포함됨
  → 2단 파티션 하위 합산을 위해 별도 로직 불필요
- 각 출력 라인: `<bytes> <path>` 형식, path에서 정규식으로 `{partition_col}=yyyy-MM-dd` 패턴 매칭하여 날짜 추출
- 날짜 파싱 실패 라인은 스킵 + 경고 로그 (형식 이탈 디렉토리 대비)
- 파싱된 날짜 중 최소값 → `min_file_date`

### 3. 갭 일수 계산

```
갭 일수 = (min_partition_date - min_file_date).days
```

- `min_file_date >= min_partition_date`인 경우 갭 없음으로 간주, 용량 계산 스킵 후 정상 종료

### 4. 갭 용량 계산 (재조회 없이 메모리 상에서 처리)

- 2번 단계에서 이미 확보한 `(bytes, date)` 리스트를 필터링
- 조건: `min_file_date <= date <= min_partition_date - 1일`
- 해당하는 `bytes` 합산 → GB 변환 (1024^3 기준)

### 5. 출력

단일 테이블 모드:
```
테이블명: db.table_name
gap날짜 : 2023-01-01 ~ 2025-06-30 (911일)
gap용량 : 123.45 GB
```

- 파티션 개수는 출력하지 않음 (요구사항에 따라 제외)
- 갭 용량 단위는 MB / GB / TB 중 최대 TB까지 자동 전환 (1GB 미만 → MB, 1024GB 이상 → TB)

### 6. 배치 모드 (여러 테이블 일괄 진단)

```
python3 partition_gap_analyzer.py --list tables.txt --output result.csv
```

- `tables.txt`: 한 줄에 `db.table` 하나씩, `#`으로 시작하는 줄은 주석으로 무시
- 단일 Impala 커넥션을 재사용하여 테이블마다 순회하며 분석 (테이블마다 재연결하지 않음)
- 각 테이블 처리 중 예외 발생 시 해당 테이블만 스킵하고 다음 테이블 계속 진행 (일괄 진단이 한 테이블 실패로 전체 중단되지 않도록)
- 결과를 CSV로 저장: 컬럼 `table,gap_day,gap_size,status,error`
  - `gap_size`는 GB 단위 숫자로 통일 (스프레드시트에서 정렬/합산 가능하도록 MB/TB 전환 없이 고정)
  - `status`: `OK`(갭 발견) / `NO_GAP`(갭 없음) / `FAIL`(조회 중 예외 발생) — 모든 테이블이 CSV에 기록되며, 실패한 테이블도 누락 없이 `error` 컬럼에 예외 메시지와 함께 남음
- 단일 테이블 모드와 배치 모드는 `table`(위치 인자) / `--list`(파일 경로) 중 하나만 지정하는 상호 배타적 옵션으로 구분

### 7. 진행도 표시

- 배치 모드: 테이블 단위 진행도 `[i/N] db.table 분석 중...` 출력
- 각 테이블 분석 내부: 단계별 진행도 `[1/4] DESCRIBE FORMATTED 조회 중...` ~ `[4/4] 갭 계산 중...` 출력 (단일 테이블 모드에서도 동일하게 표시됨)

## 설정 값 (스크립트 상단 상수)

- `IMPALA_HOST`, `IMPALA_PORT`
- `LDAP_USER`, `LDAP_PASSWORD`
- SSL 인증서 경로
- Kerberos 인증 불필요

테이블명은 argparse로 실행 시 입력받음.

## 예외 처리 원칙

- Non-partitioned 테이블 → 명확한 에러 메시지 후 종료
- LOCATION 또는 파티션 컬럼 파싱 실패 → `RuntimeError`로 즉시 실패 (단발성 스크립트이므로 `AirflowFailException` 미사용)
- `hdfs dfs -du -s` 실행 실패(권한 거부, 경로 없음 등) → 에러 출력 후 종료
- 날짜 형식이 아닌 디렉토리명은 무시하되 반드시 경고 로그 남김 (묵시적 스킵 금지)

## 코딩 컨벤션

- Python3, snake_case (PEP8)
- 주석: 한국어
- 타입 힌트 사용
- 헬퍼 함수는 인라인 처리 (과도한 함수 분리 지양, 플랫한 구조 선호)
- 코드는 채팅창 직접 출력 (아티팩트 미사용)

## 향후 고려 사항 (미확정)

- 2단 파티션 String 값 개별 단위의 세부 진단이 필요해질 경우 별도 확장 검토
- Airflow DAG화 여부는 미정 (현재는 수동 실행 스크립트로 설계)
