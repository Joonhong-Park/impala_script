# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Impala 클러스터 테이블 헬스체커. 여러 Impala 클러스터에 동시 접속해 `tables.txt`에 나열된 테이블들의 접근 가능 여부를 확인하고, 결과를 표 형식으로 출력 및 로그 파일로 저장한다.

## 실행 방법

```bash
bash check_tables.sh
```

- 실행 전 `tables.txt`에 확인할 테이블 목록을 `db.tablename` 형식으로 작성
- 결과는 터미널 출력과 함께 `result_YYYYMMDD_HHMMSS.log` 파일로 저장됨
- `impala-shell`이 PATH에 있어야 함

## 설정

`check_tables.sh` 상단의 설정 섹션에서 수정:

| 변수 | 설명 |
|---|---|
| `CLUSTER_NAMES` | 클러스터 표시 이름 배열 |
| `CLUSTER_HOSTS` | 클러스터 호스트 주소 배열 (NAMES와 순서 일치 필요) |
| `CLUSTER_PORT` | Impala HiveServer2 포트 (기본 21050) |
| `LDAP_USER` / `LDAP_PASS` | LDAP 인증 정보 |

## 구조

- `check_tables.sh` — 메인 스크립트. 클러스터별로 `run_cluster()`를 백그라운드 병렬 실행하고, 임시 디렉토리(`.work_$$`)에 결과 파일(`<cidx>_<tidx>`)을 저장한 뒤 종료 시 자동 삭제
- `tables.txt` — 점검 대상 테이블 목록. `#`으로 시작하는 줄은 주석 처리

## 출력 형식

- 표: 행=테이블, 열=클러스터, 값=`O`(PASS) / `X`(FAIL) / `-`(N/A), 오른쪽에 Exception 컬럼
- FAIL Summary: 클러스터별 실패 테이블 목록과 에러 키
- 전체 PASS/FAIL 집계
