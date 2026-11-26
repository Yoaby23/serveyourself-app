#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
for suite in supabase/tests/*.sql; do
    printf 'Suite %s\n' "$suite"
    {
        printf 'BEGIN;\n'
        cat "$suite"
        printf '\nROLLBACK;\n'
    } | psql 'postgresql://postgres:postgres@127.0.0.1:54322/postgres' -X -v ON_ERROR_STOP=1
done
