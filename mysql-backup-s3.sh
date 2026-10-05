#!/usr/bin/env bash
#
# mysql-backup-s3.sh — per-database MySQL/MariaDB backups to Amazon S3.
#
# Dumps every database (except system DBs), compresses each with gzip,
# optionally encrypts with GPG, uploads to S3 with a date-stamped name,
# then prunes local and remote copies older than the retention window.
#
# Safe for cron: logs to a file, locks against overlapping runs, exits
# non-zero on any failure so your monitoring notices.
#
# Credentials: uses a MySQL option file (~/.my.cnf) — NEVER put the
# password in this script's variables.
#
#   [client]
#   user = backup
#   password = STRONG-PASSWORD-HERE
#   host = localhost
#
# Required: mysql, mysqldump, gzip, aws (AWS CLI v2 with a configured profile)
# Optional: gpg (only when ENCRYPT=true)
#
# Cron example (daily 2:30 AM):
#   30 2 * * * /opt/mysql-backup-s3/mysql-backup-s3.sh >> /var/log/mysql-backup-s3.log 2>&1
#
set -euo pipefail

# ---------------------------------------------------------------- config ----

S3_BUCKET="s3://my-db-backups/mysql"   # destination bucket/prefix
BACKUP_DIR="/var/backups/mysql"        # local staging dir (needs ~2x largest DB free)
RETENTION_DAYS=14                      # keep this many daily backups (local + S3)
ENCRYPT=false                          # set true to GPG-encrypt before upload
GPG_RECIPIENT="backups@example.com"    # GPG key id/email used when ENCRYPT=true
AWS_PROFILE="default"                  # AWS CLI profile
MYSQL_DEFAULTS_FILE="$HOME/.my.cnf"   # MySQL client option file (see header)
LOG_FILE="/var/log/mysql-backup-s3.log"
LOCK_FILE="/var/lock/mysql-backup-s3.lock"

# ------------------------------------------------------------- functions ----

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; exit 1; }

# --------------------------------------------------------------- main -------

# Prevent overlapping runs (stale lock from a crashed run is detected via flock).
exec 9>"$LOCK_FILE" || fail "cannot open lock file $LOCK_FILE"
flock -n 9 || fail "another backup is already running"

for cmd in mysql mysqldump gzip aws; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command missing: $cmd"
done
if [[ "$ENCRYPT" == true ]]; then
    command -v gpg >/dev/null 2>&1 || fail "ENCRYPT=true but gpg is missing"
fi
[[ -r "$MYSQL_DEFAULTS_FILE" ]] || fail "MySQL defaults file not readable: $MYSQL_DEFAULTS_FILE"
mkdir -p "$BACKUP_DIR"

DATESTAMP="$(date +%F)"
log "=== backup run started ($DATESTAMP) ==="

# Collect database list (plain names, one per line).
mapfile -t DATABASES < <(
    mysql --defaults-file="$MYSQL_DEFAULTS_FILE" -N -e "SHOW DATABASES;" \
    | grep -vxF \
        -e information_schema \
        -e performance_schema \
        -e sys \
        -e mysql \
    || true
)
[[ ${#DATABASES[@]} -gt 0 ]] || fail "no databases found to back up"

for db in "${DATABASES[@]}"; do
    outfile="$BACKUP_DIR/${db}-${DATESTAMP}.sql.gz"
    log "dumping: $db"
    # --single-transaction: consistent InnoDB dump without locking tables.
    # --routines --triggers --events: don't silently lose stored procedures.
    mysqldump --defaults-file="$MYSQL_DEFAULTS_FILE" \
        --single-transaction --quick --routines --triggers --events \
        "$db" | gzip -9 > "$outfile" \
        || fail "mysqldump failed for $db"

    # Sanity check: a dump under ~100 bytes is almost certainly an error page/empty.
    if [[ $(stat -c%s "$outfile") -lt 100 ]]; then
        fail "dump of $db is suspiciously small — aborting before upload"
    fi

    upload_file="$outfile"
    if [[ "$ENCRYPT" == true ]]; then
        log "encrypting: $db"
        gpg --batch --yes --trust-model always \
            --recipient "$GPG_RECIPIENT" --encrypt --output "${outfile}.gpg" "$outfile" \
            || fail "gpg encryption failed for $db"
        rm -f "$outfile"
        upload_file="${outfile}.gpg"
    fi

    log "uploading: $(basename "$upload_file")"
    aws --profile "$AWS_PROFILE" s3 cp "$upload_file" "$S3_BUCKET/$(basename "$upload_file")" \
        --storage-class STANDARD_IA \
        || fail "S3 upload failed for $db"
done

# ---- retention: local -------------------------------------------------------
log "pruning local backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.sql.gz.gpg' \) \
    -mtime +"$RETENTION_DAYS" -print -delete >> "$LOG_FILE" 2>&1 || true

# ---- retention: S3 ------------------------------------------------------------
# S3 has no "mtime"; the datestamp in the filename (DB-YYYY-MM-DD.sql.gz)
# is the source of truth. Cutoff = today minus retention.
CUTOFF="$(date -d "$RETENTION_DAYS days ago" +%F)"
log "pruning S3 objects with datestamp older than $CUTOFF"
aws --profile "$AWS_PROFILE" s3 ls "$S3_BUCKET/" | while read -r _ _ _ key; do
    # key looks like: mydb-2026-10-05.sql.gz  (or .sql.gz.gpg)
    if [[ "$key" =~ -([0-9]{4}-[0-9]{2}-[0-9]{2})\.sql\.gz(\.gpg)?$ ]]; then
        if [[ "${BASH_REMATCH[1]}" < "$CUTOFF" ]]; then
            log "deleting from S3: $key"
            aws --profile "$AWS_PROFILE" s3 rm "$S3_BUCKET/$key" >> "$LOG_FILE" 2>&1
        fi
    fi
done

log "=== backup run finished OK (${#DATABASES[@]} databases) ==="
