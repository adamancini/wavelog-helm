#!/usr/bin/env bash
# Dump the Wavelog database to /backup and prune old dumps.
# Inputs (env): DB_HOST DB_PORT DB_NAME DB_USER MYSQL_PWD RETENTION
# The dump is written under a temporary name and renamed only after gzip has
# verified it, so a failed run never leaves a truncated dump that retention
# would count as the newest one.
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/backup}
: "${RETENTION:?RETENTION is required}"
case $RETENTION in
  '' | *[!0-9]* | 0) echo "backup: RETENTION must be a positive integer" >&2; exit 1 ;;
esac

cd "$BACKUP_DIR"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
final="wavelog-$stamp.sql.gz"
tmp=".$final.tmp"

cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

# Leftovers from a killed run (concurrencyPolicy Forbid means none is live).
rm -f -- .wavelog-*.sql.gz.tmp

echo "backup: dumping $DB_NAME from $DB_HOST:$DB_PORT to $final"
mariadb-dump --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
  --single-transaction --routines --triggers "$DB_NAME" | gzip >"$tmp"
gzip -t -- "$tmp"
mv -- "$tmp" "$final"

# Timestamped names sort chronologically; only completed dumps match the glob.
{ ls -1 -- wavelog-*.sql.gz 2>/dev/null || true; } | sort -r | tail -n +$((RETENTION + 1)) | xargs -r rm -f --
echo "backup: done, $(ls -1 -- wavelog-*.sql.gz | wc -l | tr -d ' ') dump(s) kept"
