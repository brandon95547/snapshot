# snapshot backup system

Full-box backup for the Phansora stack, built for **migrating to a new
production server**. One script snapshots everything needed to stand the site
back up on fresh hardware.

## What it backs up

| # | Component | How | Why it matters |
|---|-----------|-----|----------------|
| 1 | Site code under `$WWW_DIR` (`phansora`, `phansora-api`) | `tar` | Includes the `.env` **secrets** (Google/Square keys, DB creds). Heavy rebuildable dirs like `node_modules`/`.venv` are excluded. |
| 2 | **Postgres database** | `pg_dump` from the `phansora_postgres` container | The DB lives in a Docker **named volume**, not on disk — a plain `/var/www` tar silently misses it. This is the #1 thing people lose in a migration. |
| 3 | Docker named volumes (e.g. `media`) | raw `tar` | User-uploaded / generated media that isn't in the code tree. |
| 4 | systemd units `phansora.service`, `phansora-api.service` | copy + record enabled state and drop-ins | So the services come back up the same way. |
| 5 | nginx config (`/etc/nginx`) | `tar` | Vhosts, proxy config, TLS wiring. |
| 6 | TLS certs (`/etc/letsencrypt`) | `tar -h` (symlinks dereferenced) | Site is HTTPS; avoids a cold re-issue / rate-limit surprise. |
| 7 | Crontabs (user + `/etc/cron.d`) | dump | Any other scheduled jobs on the box. |
| 8 | Environment inventory | text | Docker/OS versions, running containers, effective nginx config — a reference for rebuilding. |

Each run produces `phansora-backup-<host>-<timestamp>.tar.gz` (+ a `.log`) in
`$BACKUP_ROOT` (default `/var/backups/phansora`), with a `MANIFEST.txt` and
`SHA256SUMS` inside.

## Setup

```bash
cd /path/to/backup-cron
cp backup.conf.example backup.conf
# edit backup.conf — at minimum confirm WWW_DIR for the prod box
sudo ./backup.sh
```

Run as **root** so `/etc`, Let's Encrypt, Docker volumes, and the root crontab
are readable. The script is *fail-soft*: a missing path is a warning, not a
crash, and the run exits non-zero if anything warned (so cron can alert you).

## Run it from cron

Nightly at 3:15am, as root:

```cron
15 3 * * * /path/to/backup-cron/backup.sh -c /path/to/backup-cron/backup.conf >> /var/log/phansora-backup.log 2>&1
```

(`sudo crontab -e`). Retention is handled inside the script via
`RETENTION_DAYS` in `backup.conf`.

## Moving the backup off-box

The archive is only a migration safety net if it lives somewhere other than the
old server. After the run, copy it to the new box (or object storage):

```bash
scp /var/backups/phansora/phansora-backup-*.tar.gz  newbox:/var/backups/phansora/
```

## Restore on the new box

`restore.sh` is the inverse of `backup.sh` — it consumes an archive and rebuilds
the box. Copy an archive over, then:

```bash
# 0. Install docker + docker compose + nginx + certbot on the new box first.
#    Copy backup.conf over too (restore.sh reads the same file for paths).

# 1. See exactly what it will do — changes nothing:
sudo ./restore.sh -f /var/backups/phansora/phansora-backup-<host>-<stamp>.tar.gz --dry-run

# 2. Do it (prompts before overwriting; type 'restore' to confirm):
sudo ./restore.sh -f /var/backups/phansora/phansora-backup-<host>-<stamp>.tar.gz
```

With no `-f`, it restores the **newest** archive in `$BACKUP_ROOT`. In order it:
verifies `SHA256SUMS` → restores code to `$WWW_DIR` → restores nginx + certs →
restores docker volumes → brings up Postgres and loads the DB dump → installs
the systemd units and re-enables the ones that were enabled on the old box.

Useful flags:

| Flag | Effect |
|------|--------|
| `--dry-run` | Print every action, change nothing. **Run this first.** |
| `--yes` | Skip the confirmation prompt (automation). |
| `--stack` | After restore, `docker compose up -d` both apps. Omit to start them via systemd instead. |
| `--with-cron` | Also restore the captured crontab (off by default). |
| `--skip-db` / `--skip-volumes` / `--skip-certs` | Restore selectively. |

**After it finishes** (it prints these too):

```bash
# reinstall the deps that were excluded from the backup to keep it small
cd /var/www/phansora     && npm ci
cd /var/www/phansora-api && python -m venv .venv && .venv/bin/pip install -r requirements.txt

nginx -t && systemctl reload nginx
systemctl start phansora.service phansora-api.service   # or use --stack during restore
# point DNS at the new box, then verify https://www.phansora.com
```

The restore is **destructive** (it overwrites `/var/www`, `/etc/nginx`,
`/etc/letsencrypt` and loads the DB) and refuses to run until you confirm or
pass `--yes`. It's *fail-soft* like the backup and exits non-zero if anything
warned.

## Notes / caveats

- **`DB_USER` / `DB_NAME`** are auto-read from `phansora/.env` if left blank in
  `backup.conf`.
- The backup contains **plaintext secrets** (`.env`, TLS private keys). Keep the
  archives root-only and encrypt them if pushing to remote/object storage.
- The database is captured as a **logical dump**, not a raw volume copy — safe
  and portable across the same Postgres major version (15).
- This dev checkout keeps the apps in `/home/crimson/sites`, not `/var/www`. Set
  `WWW_DIR` accordingly if you ever run it here for testing.
