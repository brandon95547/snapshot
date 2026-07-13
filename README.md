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

### Hourly, overwrite-in-place (single file — no accumulation)

To run every hour and keep only the newest snapshot (no pile-up of old
archives), set `SINGLE_FILE=1` in `backup.conf` and schedule it hourly:

```cron
0 * * * * /path/to/backup-cron/backup.sh -c /path/to/backup-cron/backup.conf >> /var/log/phansora-backup.log 2>&1
```

In single-file mode the script writes **one** archive that is replaced in place
each run:

- `phansora-backup-latest.tar.gz` — the archive (atomic `mv` into place)
- `phansora-backup-latest.log`    — the log (overwritten each run)
- `phansora-backup-latest.json`   — metadata sidecar: last-run time, size,
  status (`ok`/`warn`), sha256

`RETENTION_DAYS` is ignored here (there's only ever one file). Overlapping runs
are prevented by a `flock` on `.backup.lock`, so a slow hourly run won't collide
with the next tick.

**Dashboard integration:** the phansora admin console (**Dashboard → Admin →
Storage**) reads the `.json` sidecar to show when the backup last ran and offers
a download link for `phansora-backup-latest.tar.gz`. For that to work the backup
directory (`BACKUP_ROOT`, default `/var/backups/phansora`) must be bind-mounted
read-only into the `phansora_node_app` container — this is wired in
`phansora/docker-compose.prod.yml` (`BACKUP_DIR` env + the `:ro` mount).
⚠️ The archive contains plaintext secrets and TLS private keys; the download
endpoint is gated to the admin session (`ADMIN_EMAIL`) and served only over
HTTPS.

## Moving the backup off-box

The archive is only a migration safety net if it lives somewhere other than the
old server. After the run, copy it to the new box (or object storage):

```bash
scp /var/backups/phansora/phansora-backup-*.tar.gz  newbox:/var/backups/phansora/
```

## Restore on the new box

`restore.sh` is the inverse of `backup.sh`. Read the **Gotchas** below before you
start — every one of them cost real debugging time during the first migration.

### ⚠️ Gotchas that will bite you (read first)

1. **Pass the OUTER `.tar.gz` to `-f` — never the inner `database.sql.gz`.**
   `restore.sh` starts by `tar xzf`-ing whatever you give it; point it at
   `phansora-backup-<host>-<stamp>.tar.gz`, not a file inside the extracted dir.
2. **Always use the PROD compose: `-f docker-compose.prod.yml`.** Plain
   `docker compose up` uses `docker-compose.yml` (**dev** — `NODE_ENV=development`,
   `nodemon`, and it creates the `phansora_db_dev` volume). That gives you an
   **empty** DB that migrates from scratch — not your data.
3. **Nothing may be running before you load the DB.** Both compose files name the
   container `phansora_postgres`, so if a container is already up, the dump loads
   into whatever volume *that* one is on (possibly the empty dev volume). Run
   `docker compose down` on both files first and confirm `docker ps` is clean.
4. **Load the dump BEFORE starting the app.** The app runs `db:migrate` on
   startup: on an empty DB it scaffolds a fresh schema (no users); on a
   dump-loaded DB it sees every migration already recorded and **skips them**.
   *"Migrations skipped" is how you know the restore worked.*
5. **Verify:** `select count(*) from users;` — non-zero = your data is really there.

### The proven flow

Two modes. **Mode A** on a clean box; **Mode B** if code is already in place and
you only need the database.

**Mode A — clean box, let the script do it all:**
```bash
# 0. Prereqs: docker + compose + nginx + certbot installed. Copy the archive and
#    the snapshot/ folder (has restore.sh + backup.conf) onto the new box.
#    (restore.sh warns if nginx isn't installed, and opens the firewall for you.)
cd /var/www/snapshot

# 1. Preview (changes nothing) — pass the OUTER archive:
sudo ./restore.sh -f /var/backups/phansora/phansora-backup-<host>-<stamp>.tar.gz --dry-run

# 2. Restore (type 'restore' to confirm). Brings up prod Postgres, loads the
#    dump, restores code/nginx/certs/systemd. Does NOT start the app.
sudo ./restore.sh -f /var/backups/phansora/phansora-backup-<host>-<stamp>.tar.gz

# 3. Start the app LAST (migrations will skip):
cd /var/www/phansora && docker compose -f docker-compose.prod.yml up -d
```

**Mode B — DB only (code/.env already present, don't want them overwritten):**
```bash
cd /var/www/phansora
docker compose down                              # stop dev stack if up
docker compose -f docker-compose.prod.yml down   # harmless if not up
docker ps | grep phansora_postgres               # MUST print nothing

docker compose -f docker-compose.prod.yml up -d db   # prod postgres, postgres_data volume
sleep 8                                              # let it accept connections

grep -E '^DB_(USER|NAME)=' /var/www/phansora/.env    # real creds

# extract the archive once if you haven't:  tar xzf <outer>.tar.gz  (creates a dir)
gunzip -c /var/backups/phansora/phansora-backup-<host>-<stamp>/database.sql.gz \
  | docker exec -i phansora_postgres psql -U <DB_USER> -d <DB_NAME>

docker exec -it phansora_postgres psql -U <DB_USER> -d <DB_NAME> -c "select count(*) from users;"
docker compose -f docker-compose.prod.yml up -d      # start app last
```

### restore.sh flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Print every action, change nothing. **Run this first.** |
| `--yes` | Skip the confirmation prompt (automation). |
| `--stack` | After restore, start both apps via `docker compose`. Omit to start manually / via systemd. |
| `--with-cron` | Also restore the captured crontab (off by default). |
| `--skip-db` / `--skip-volumes` / `--skip-certs` | Restore selectively (e.g. DB already loaded manually). |
| `--skip-firewall` | Don't touch the firewall (by default it opens http/https). |

### After the DB is in — finish the box

```bash
# Frontend deps (excluded from the backup to keep it small):
cd /var/www/phansora && npm ci

# API deps — NOT plain `python -m venv`. On CentOS Stream 8 the default python3
# is 3.6, but the torch wheels are cp310, so you MUST build the venv with
# Python 3.10. See "API on CentOS Stream 8" below.

nginx -t && systemctl reload nginx
# point DNS at the new box, then verify https://www.phansora.com
```

The restore is **destructive** (overwrites `/var/www`, `/etc/nginx`,
`/etc/letsencrypt` and loads the DB) and refuses to run until you confirm or pass
`--yes`. It's *fail-soft* and exits non-zero if anything warned.

### Re-running on a box that already has state

`restore.sh` is **idempotent** — safe to run again on the same box if something
went wrong, without errors:

- **Code / nginx / certs** extract with `--overwrite`, so existing files
  (including `.env`) and the `/etc/letsencrypt` `live/*` symlinks are cleanly
  replaced.
- **Database**: before loading, it stops the `app` container (to drop live
  connections) and **drops & recreates** the target DB, so the dump always loads
  into an empty database — no leftover objects, no lock conflicts. (If the drop
  can't complete because something reconnected, it falls back to the dump's
  built-in `--clean` and warns.)

So a re-run replaces everything and ends in the same state as a first run. Just
remember the same rule: nothing but `db` should be started until the load
finishes; bring the app up last.

## API on CentOS Stream 8 (GPU box)

The `phansora-api` venv needs **Python 3.10** — the pinned torch wheels are
`cp310` (CUDA `cu126`, for the RTX A4000) and `pyproject.toml` requires `>=3.10`.
CentOS Stream 8 ships only 3.6/3.8/3.9, so install 3.10 (e.g. via `uv`):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.bashrc
uv python install 3.10
cd /var/www/phansora-api
rm -rf .venv && uv venv --python 3.10 .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt        # CUDA torch, self-contained — no system CUDA needed
.venv/bin/pip install -e .
# verify the GPU is visible:
.venv/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available())"  # -> 2.8.0+cu126 True
```

Do **not** run `make install` (its `install` target hardcodes `python3 -m venv`,
which recreates the broken 3.6 venv). The GPU only needs the NVIDIA **driver**
(`nvidia-smi`), not the CUDA toolkit — the wheels bundle their own runtime.

## Notes / caveats

- **nginx isn't in the backup — only its config is.** The nginx *package* must be
  installed on the new box (`dnf install nginx` / `apt install nginx`); `restore.sh`
  warns if it's missing, restores `/etc/nginx`, and opens the firewall.
- **Firewall:** `restore.sh` opens http/https (and keeps ssh) automatically —
  `firewalld` on CentOS/RHEL, `ufw` on Debian/Ubuntu. Pass `--skip-firewall` to
  leave it alone. The old box's firewall state is recorded in the backup's
  `inventory.txt` for reference. The equivalent manual firewalld commands:
  `firewall-cmd --permanent --add-service={http,https} && firewall-cmd --reload`.
- **`DB_USER` / `DB_NAME`** are auto-read from `phansora/.env` if left blank in
  `backup.conf`.
- **Prod docker volumes:** only `phansora_postgres_data` is the real prod DB
  volume (declared in `docker-compose.prod.yml`). `phansora_db_dev` and
  `phansora_node_modules` are *dev* leftovers — safe to `docker volume rm` once
  the prod stack on `postgres_data` has your data. The DB is never restored as a
  raw volume; it's a `pg_dump` loaded via `psql`.
- The backup contains **plaintext secrets** (`.env`, TLS private keys). Keep the
  archives root-only and encrypt them if pushing to remote/object storage.
- The database is a **logical dump** — portable across the same Postgres major
  version (15).
- This dev checkout keeps the apps in `/home/crimson/sites`, not `/var/www`. Set
  `WWW_DIR` accordingly if you ever run it here for testing.
