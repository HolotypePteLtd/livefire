#!/usr/bin/env bash
# Applies the Openfire migrations inside a Supabase PostgreSQL container.
#
# SUPABASE_DB_CONTAINER=<name> ./scripts/apply-migrations.sh
set -euo pipefail

CONTAINER="${SUPABASE_DB_CONTAINER:?set the Supabase PostgreSQL container name}"
DB_USER="${SUPABASE_DB_USER:-supabase_admin}"
DB_NAME="${SUPABASE_DB_NAME:-postgres}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATIONS="$HERE/migrations"

[ -d "$MIGRATIONS" ] || { echo "no migrations dir: $MIGRATIONS" >&2; exit 1; }
shopt -s nullglob
files=("$MIGRATIONS"/*.sql)
[ "${#files[@]}" -gt 0 ] || { echo "no *.sql migrations in $MIGRATIONS" >&2; exit 1; }

for file in "${files[@]}"; do
  echo "==> applying $(basename "$file")"
  docker exec -i "$CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$file"
done

echo "==> notify pgrst"
docker exec -i "$CONTAINER" \
  psql -U "$DB_USER" -d "$DB_NAME" -c "NOTIFY pgrst, 'reload schema';"

echo "ok: ${#files[@]} migration(s) applied to $CONTAINER"
