#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

supabase_cli() {
  pnpm dlx supabase@2.118.0 "$@"
}

local_psql() {
  docker exec -i supabase_db_field-maps psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

configure_api() {
  mkdir -p database/.local
  chmod 700 database/.local
  if [ ! -f database/.local/fieldmaps-api-password ]; then
    (umask 077; openssl rand -hex 32 > database/.local/fieldmaps-api-password)
  fi
  chmod 600 database/.local/fieldmaps-api-password
  task_password=$(cat database/.local/fieldmaps-api-password)
  printf "ALTER ROLE fieldmaps_api PASSWORD '%s';\n" "$task_password" | local_psql >/dev/null
}

case "${1:-help}" in
  start)
    supabase_cli start >/dev/null
    configure_api
    printf '%s\n' 'Local Supabase ready. Studio: http://127.0.0.1:54323; Mailpit: http://127.0.0.1:54324'
    ;;
  stop) supabase_cli stop ;;
  reset)
    supabase_cli db reset --local --yes >/dev/null
    configure_api
    ;;
  test)
    docker exec supabase_db_field-maps mkdir -p /tmp/fieldmaps-tests/supabase /tmp/fieldmaps-tests/database
    docker cp database/tests supabase_db_field-maps:/tmp/fieldmaps-tests/database/
    docker cp supabase/seed.sql supabase_db_field-maps:/tmp/fieldmaps-tests/supabase/seed.sql
    docker cp database/hosted/verify.sql supabase_db_field-maps:/tmp/fieldmaps-tests/database/verify.sql
    local_psql -f /tmp/fieldmaps-tests/database/tests/run.sql
    local_psql -f /tmp/fieldmaps-tests/database/verify.sql
    ;;
  api-test)
    cd backend
    uv run --frozen pytest
    ;;
  help|--help|-h)
    printf '%s\n' 'Usage: sh database/local-supabase.sh start|stop|reset|test|api-test' \
      'reset deletes only the local Supabase database contents and reapplies canonical migrations.'
    ;;
  *) printf '%s\n' 'Unknown command. Use --help.' >&2; exit 2 ;;
esac
