# backup-cron

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

```bash
# 0. Install docker + docker compose + nginx + certbot first.

# 1. Unpack the backup.
cd /var/backups/phansora
tar xzf phansora-backup-<host>-<stamp>.tar.gz
cd phansora-backup-<host>-<stamp>
sha256sum -c SHA256SUMS          # verify integrity

# 2. Restore code.
mkdir -p /var/www && tar xzf www.tar.gz -C /var/www --strip-components=1
#   (adjust --strip-components / target so phansora + phansora-api land in /var/www)
#   Then reinstall deps that were excluded:
#     cd /var/www/phansora     && npm ci
#     cd /var/www/phansora-api && python -m venv .venv && .venv/bin/pip install -r requirements.txt

# 3. nginx + TLS.
tar xzf nginx.tar.gz       -C /etc --strip-components=1   # -> /etc/nginx
tar xzf letsencrypt.tar.gz -C /etc --strip-components=1   # -> /etc/letsencrypt
nginx -t && systemctl reload nginx

# 4. Bring up the stack so Postgres exists, then load the DB.
cd /var/www/phansora
docker compose -f docker-compose.prod.yml up -d db
#   wait a few seconds for Postgres to accept connections, then:
gunzip -c /var/backups/phansora/.../database.sql.gz \
  | docker exec -i phansora_postgres psql -U "$DB_USER" -d "$DB_NAME"
docker compose -f docker-compose.prod.yml up -d       # full stack
cd /var/www/phansora-api && docker compose up -d

# 5. Restore any docker named volumes (media).
docker volume create <volume-name>
docker run --rm -v <volume-name>:/data -v "$PWD":/backup alpine \
  tar xzf /backup/volume-<volume-name>.tar.gz -C /data

# 6. systemd units.
cp systemd/*.service /etc/systemd/system/
[ -d systemd/*.service.d ] && cp -r systemd/*.service.d /etc/systemd/system/ 2>/dev/null
systemctl daemon-reload
#   re-enable per systemd/enabled-state.txt, e.g.:
systemctl enable --now phansora.service phansora-api.service
```

Exact `--strip-components` values depend on your prod layout — check
`MANIFEST.txt` and the archive contents before extracting over live paths.

## Notes / caveats

- **`DB_USER` / `DB_NAME`** are auto-read from `phansora/.env` if left blank in
  `backup.conf`.
- The backup contains **plaintext secrets** (`.env`, TLS private keys). Keep the
  archives root-only and encrypt them if pushing to remote/object storage.
- The database is captured as a **logical dump**, not a raw volume copy — safe
  and portable across the same Postgres major version (15).
- This dev checkout keeps the apps in `/home/crimson/sites`, not `/var/www`. Set
  `WWW_DIR` accordingly if you ever run it here for testing.
