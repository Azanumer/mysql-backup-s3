# mysql-backup-s3

Per-database MySQL/MariaDB backups straight to Amazon S3. Dumps every database (except system DBs), gzips each one, optionally GPG-encrypts it, uploads with a date-stamped filename, then prunes local and remote copies older than your retention window.

Cron-safe: file locking prevents overlapping runs, everything is logged, and any failure exits non-zero so your monitoring actually notices.

## Files

| File | What it does |
|---|---|
| `mysql-backup-s3.sh` | The backup script — dump → compress → (encrypt) → upload → prune |

## Setup

1. Create a MySQL backup user (principle of least privilege):

```sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'STRONG-PASSWORD-HERE';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
```

2. Store the credentials in `~/.my.cnf` (mode `600`) — the script never takes a password on the command line:

```ini
[client]
user = backup
password = STRONG-PASSWORD-HERE
host = localhost
```

3. Configure AWS CLI (`aws configure --profile default` or a named profile) with write access to your bucket.
4. Edit the config block at the top of the script: `S3_BUCKET`, `BACKUP_DIR`, `RETENTION_DAYS`, `ENCRYPT`.

## Run

```bash
chmod +x mysql-backup-s3.sh
./mysql-backup-s3.sh
```

Daily via cron (2:30 AM):

```cron
30 2 * * * /opt/mysql-backup-s3/mysql-backup-s3.sh >> /var/log/mysql-backup-s3.log 2>&1
```

## Details

- Uses `--single-transaction` so InnoDB dumps don't lock your live site.
- Includes routines, triggers, and events — stored procedures aren't silently lost.
- Aborts before uploading if a dump is suspiciously small (< 100 bytes).
- Remote pruning parses the `DB-YYYY-MM-DD.sql.gz` filename, so it works on any S3-compatible storage (no lifecycle rules required).
- Uploads use `STANDARD_IA` storage class to keep costs down.

Requires: `mysql`, `mysqldump`, `gzip`, AWS CLI. Optional: `gpg` (when `ENCRYPT=true`). MIT licensed.
