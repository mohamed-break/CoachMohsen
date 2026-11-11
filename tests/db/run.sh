#!/bin/bash
# Usage: tests/db/run.sh  — rebuilds a scratch database, applies every migration, then runs tests/db/*_test.sql
set -e
H=${PGHOST_DIR:-/home/claude/.pgtest}; P=${PGPORT_NUM:-54329}
cd "$(dirname "$0")/../.."
psql -h $H -p $P -U postgres -qc "drop database if exists padel_test" -qc "create database padel_test"
q(){ psql -h $H -p $P -U postgres -d padel_test -v ON_ERROR_STOP=1 -q "$@"; }
q -f tests/db/00_supabase_stub.sql
[ -f tests/db/01_legacy_seed.sql ] && q -f tests/db/01_legacy_seed.sql
for f in supabase/migrations/*.sql; do
  if [ "$(basename $f)" = "0005_clubs.sql" ] && [ -f tests/db/02_legacy_data.sql ]; then q -f tests/db/02_legacy_data.sql; fi
  q -1 -f "$f" || { echo "MIGRATION FAILED: $f"; exit 1; }
done
for t in tests/db/*_test.sql; do [ -f "$t" ] && { q -f "$t" || { echo "TEST FAILED: $t"; exit 1; }; }; done
echo "ALL DB TESTS PASSED"
