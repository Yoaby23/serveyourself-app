#!/usr/bin/env bash
# Produce a PostgreSQL archive encrypted to a public age key.
set -euo pipefail
umask 077

if [[ $# != 2 ]]; then
    echo "Uso: $0 DIRECTORIO_DE_RESPALDOS CLAVE_PUBLICA_AGE" >&2
    exit 2
fi
: "${PGHOST:?Define PGHOST con el host autorizado de PostgreSQL}"
: "${PGUSER:?Define PGUSER con el usuario autorizado de PostgreSQL}"
: "${PGDATABASE:?Define PGDATABASE con la base que se debe respaldar}"

destination=$1
recipient=$2
if [[ ! $recipient =~ ^age1[0-9a-z]{58}$ ]]; then
    echo "Usa la clave pública age de respaldo." >&2
    exit 2
fi
mkdir -p -- "$destination"
temp=$(mktemp -- "$destination/.serveyourself-XXXXXX")
trap 'rm -f -- "$temp"' EXIT

pg_dump --format=custom --no-password |
    age --encrypt --recipient "$recipient" > "$temp"

result="$destination/serveyourself-$(date -u +%Y%m%dT%H%M%SZ)-${temp##*-}.dump.age"
ln -- "$temp" "$result"
printf '%s\n' "$result"
