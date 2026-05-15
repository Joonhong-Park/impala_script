-- 파티션 추가 예시
ALTER TABLE db.table_name ADD IF NOT EXISTS
    PARTITION (dt='2026-05-15');

REFRESH db.table_name;
