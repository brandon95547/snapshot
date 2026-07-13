#!/usr/bin/env bash
#
# restore.sh — restore a Phansora backup onto a fresh box. The inverse of
# backup.sh; run it on the NEW server after copying an archive over.
#
# It will, in order:
#   1. Unpack the archive and verify SHA256SUMS
#   2. Restore site code to $WWW_DIR (incl. .env secrets)
#   3. Restore nginx config + Let's Encrypt certs
#   4. Restore Docker named volumes (media, ...)
#   5. Bring up Postgres and load the database dump
#   6. Install systemd unit files and re-enable them per captured state
#   7. Optionally start the full application stack
#   8. Optionally restore the crontab
#
# This is DESTRUCTIVE — it overwrites /var/www, /etc/nginx, /etc/letsencrypt
# and loads a DB. It refuses to touch anything until you confirm (or pass
# --yes). Use --dry-run first to see exactly what it would do.
#
# Usage:
#   sudo ./restore.sh [-c backup.conf] [-f archive.tar.gz] [options]
#
# Options:
#   -c FILE     config file (default ./backup.conf, same file backup.sh uses)
#   -f FILE     archive to restore (default: newest in $BACKUP_ROOT)
#   --dry-run   print actions without changing anything
#   --yes       skip the confirmation prompt (for automation)
#   --stack     after restore, start the full app stack via docker compose
#   --with-cron restore the captured crontab too (off by default — it can pull
#               in the backup job and unrelated entries)
#   --skip-db          don't load the database dump
#   --skip-volumes     don't restore docker named volumes
#   --skip-certs       don't restore nginx / letsencrypt
#   --skip-firewall    don't touch the firewall (default: open http/https)
#   -h          this help

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/backup.conf"
ARCHIVE=""
DRY_RUN=0
ASSUME_YES=0
START_STACK=0
WITH_CRON=0
SKIP_DB=0
SKIP_VOLUMES=0
SKIP_CERTS=0
SKIP_FIREWALL=0

# ---- arg parsing (mix of short + long) -----------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -c) CONF_FILE="$2"; shift 2 ;;
    -f) ARCHIVE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --stack) START_STACK=1; shift ;;
    --with-cron) WITH_CRON=1; shift ;;
    --skip-db) SKIP_DB=1; shift ;;
    --skip-volumes) SKIP_VOLUMES=1; shift ;;
    --skip-certs) SKIP_CERTS=1; shift ;;
    --skip-firewall) SKIP_FIREWALL=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---- config defaults (mirror backup.sh; overridden by backup.conf) --------
WWW_DIR="/var/www"
PHANSORA_DIR=""
PHANSORA_API_DIR=""
SYSTEMD_UNITS="phansora.service phansora-api.service"
NGINX_DIR="/etc/nginx"
LETSENCRYPT_DIR="/etc/letsencrypt"
PG_CONTAINER="phansora_postgres"
DB_USER=""
DB_NAME=""
BACKUP_ROOT="/var/backups/phansora"
# Compose files used to bring the stack up (relative to each project dir).
PHANSORA_COMPOSE="docker-compose.prod.yml"
PHANSORA_API_COMPOSE="docker-compose.yml"

if [ -f "$CONF_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONF_FILE"
else
  echo "note: no config at $CONF_FILE — using built-in defaults" >&2
fi
PHANSORA_DIR="${PHANSORA_DIR:-${WWW_DIR}/phansora}"
PHANSORA_API_DIR="${PHANSORA_API_DIR:-${WWW_DIR}/phansora-api}"

WARN_COUNT=0
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "[$(date +%H:%M:%S)]   ok  - $*"; }
warn() { echo "[$(date +%H:%M:%S)]  WARN - $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
# run: echo the command in dry-run, otherwise execute it.
run()  { if [ "$DRY_RUN" -eq 1 ]; then echo "       + $*"; else eval "$@"; fi; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || warn "not running as root — writes to /etc, /var/www and docker may fail (use sudo)"
command -v docker >/dev/null 2>&1 || warn "docker not found — DB and volume restore will be skipped"

# Locate the archive.
if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(ls -t "${BACKUP_ROOT}"/phansora-backup-*.tar.gz 2>/dev/null | head -1)"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { echo "FATAL: no archive found (pass -f, or put one in $BACKUP_ROOT)" >&2; exit 1; }
log "=== Phansora restore ==="
log "archive : $ARCHIVE"
log "config  : $CONF_FILE"
log "target  : WWW_DIR=$WWW_DIR NGINX=$NGINX_DIR LE=$LETSENCRYPT_DIR"
[ "$DRY_RUN" -eq 1 ] && log "MODE    : DRY RUN (no changes will be made)"

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  echo
  echo "This will OVERWRITE on this box:"
  echo "  - $WWW_DIR              (site code + .env)"
  [ "$SKIP_CERTS" -eq 0 ] && echo "  - $NGINX_DIR / $LETSENCRYPT_DIR   (config + TLS certs)"
  [ "$SKIP_DB" -eq 0 ]    && echo "  - the '$PG_CONTAINER' database   (loaded from dump)"
  echo "  - systemd units: $SYSTEMD_UNITS"
  [ "$SKIP_FIREWALL" -eq 0 ] && echo "  - firewall: open http/https (ssh kept)"
  echo
  printf "Type 'restore' to proceed: "
  read -r reply
  [ "$reply" = "restore" ] || { echo "aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# 1. Unpack + verify
# ---------------------------------------------------------------------------
log "--- [1/8] Unpack + verify"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/phansora-restore.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
run "tar xzf '$ARCHIVE' -C '$WORK'"
# The archive contains a single top-level dir (the staging basename).
SRC="$WORK"
if [ "$DRY_RUN" -eq 0 ]; then
  inner="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$inner" ] && SRC="$inner"
  if [ -f "${SRC}/SHA256SUMS" ]; then
    if ( cd "$SRC" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
      ok "checksums verified"
    else
      warn "CHECKSUM MISMATCH — archive may be corrupt; continuing but inspect carefully"
    fi
  else
    warn "no SHA256SUMS in archive — cannot verify integrity"
  fi
  [ -f "${SRC}/MANIFEST.txt" ] && { echo "----- MANIFEST -----"; cat "${SRC}/MANIFEST.txt"; echo "--------------------"; }
else
  ok "(dry-run) would extract and verify checksums"
fi

# ---------------------------------------------------------------------------
# 2. Site code
# ---------------------------------------------------------------------------
log "--- [2/8] Site code -> $WWW_DIR"
if [ -f "${SRC}/www.tar.gz" ] || [ "$DRY_RUN" -eq 1 ]; then
  run "mkdir -p '$WWW_DIR'"
  # www.tar.gz was packed as '-C dirname(SRC_WWW) basename(SRC_WWW)', so its
  # single top-level component is the *source* dir name (e.g. 'www' or 'sites').
  # --strip-components=1 drops that name and lands the project folders
  # (phansora, phansora-api, ...) directly in this box's $WWW_DIR — robust even
  # if the source box used a different path (dev 'sites' vs prod 'www').
  run "tar xzf '${SRC}/www.tar.gz' -C '$WWW_DIR' --strip-components=1 --overwrite"
  ok "restored site code -> $WWW_DIR"
  echo "       note: reinstall excluded deps -> (cd $PHANSORA_DIR && npm ci); (cd $PHANSORA_API_DIR && python -m venv .venv && .venv/bin/pip install -r requirements.txt)"
else
  warn "www.tar.gz not in archive — code NOT restored"
fi

# ---------------------------------------------------------------------------
# 3. nginx + TLS certs
# ---------------------------------------------------------------------------
log "--- [3/8] nginx + TLS certs + firewall"

# nginx must be installed to serve the restored config (it's not in the backup).
if command -v nginx >/dev/null 2>&1; then
  ok "nginx is installed ($(nginx -v 2>&1 | sed 's/nginx version: //'))"
else
  warn "nginx is NOT installed — install it before starting the site (CentOS: 'dnf install nginx'; Debian: 'apt install nginx')"
fi

# Restore config + certs (unless --skip-certs).
if [ "$SKIP_CERTS" -eq 0 ]; then
  if [ -f "${SRC}/nginx.tar.gz" ] || [ "$DRY_RUN" -eq 1 ]; then
    run "mkdir -p '$NGINX_DIR'"
    run "tar xzf '${SRC}/nginx.tar.gz' -C '$NGINX_DIR' --strip-components=1 --overwrite"
    ok "restored $NGINX_DIR"
  else
    warn "nginx.tar.gz not in archive"
  fi
  if [ -f "${SRC}/letsencrypt.tar.gz" ] || [ "$DRY_RUN" -eq 1 ]; then
    run "mkdir -p '$LETSENCRYPT_DIR'"
    run "tar xzf '${SRC}/letsencrypt.tar.gz' -C '$LETSENCRYPT_DIR' --strip-components=1 --overwrite"
    ok "restored $LETSENCRYPT_DIR"
  else
    warn "letsencrypt.tar.gz not in archive (no certs to restore)"
  fi
else
  log "  config/cert restore skipped (--skip-certs)"
fi

# Open the firewall for web traffic so the site is actually reachable. SSH is
# always (re)allowed first so a re-run can never lock you out. Idempotent.
if [ "$SKIP_FIREWALL" -eq 0 ]; then
  if command -v firewall-cmd >/dev/null 2>&1; then          # RHEL / CentOS -> firewalld
    if firewall-cmd --state >/dev/null 2>&1; then
      run "firewall-cmd --permanent --add-service=ssh   >/dev/null 2>&1 || true"
      run "firewall-cmd --permanent --add-service=http  >/dev/null 2>&1 || true"
      run "firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true"
      run "firewall-cmd --reload >/dev/null 2>&1 || true"
      ok "firewalld: opened http/https (ssh kept)"
    else
      warn "firewalld installed but not running — enable it (ssh is in the default zone) then open web: systemctl enable --now firewalld; firewall-cmd --permanent --add-service={http,https}; firewall-cmd --reload"
    fi
  elif command -v ufw >/dev/null 2>&1; then                 # Debian / Ubuntu -> ufw
    run "ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true"
    run "ufw allow 'Nginx Full' >/dev/null 2>&1 || ufw allow 80,443/tcp >/dev/null 2>&1 || true"
    ok "ufw: allowed ssh + http/https"
  else
    warn "no firewalld/ufw detected — if a firewall is active, open ports 80 and 443 manually"
  fi
else
  log "  firewall left untouched (--skip-firewall)"
fi

# ---------------------------------------------------------------------------
# 4. Docker named volumes
# ---------------------------------------------------------------------------
if [ "$SKIP_VOLUMES" -eq 0 ] && command -v docker >/dev/null 2>&1; then
  log "--- [4/8] Docker named volumes"
  found=0
  for vtar in "${SRC}"/volume-*.tar.gz; do
    [ -e "$vtar" ] || continue
    found=1
    vname="$(basename "$vtar")"; vname="${vname#volume-}"; vname="${vname%.tar.gz}"
    run "docker volume create '$vname' >/dev/null"
    run "docker run --rm -v '${vname}:/data' -v '${SRC}:/backup' alpine tar xzf '/backup/$(basename "$vtar")' -C /data"
    ok "restored volume '$vname'"
  done
  [ "$found" -eq 1 ] || log "  (no volume-*.tar.gz in archive)"
else
  log "--- [4/8] Docker named volumes  (skipped)"
fi

# ---------------------------------------------------------------------------
# 5. Database: bring up Postgres, load the dump
# ---------------------------------------------------------------------------
if [ "$SKIP_DB" -eq 0 ] && command -v docker >/dev/null 2>&1; then
  log "--- [5/8] Database"
  if [ -f "${SRC}/database.sql.gz" ] || [ "$DRY_RUN" -eq 1 ]; then
    # Read creds from the just-restored phansora/.env if not set in config.
    _envf="${PHANSORA_DIR}/.env"
    [ -z "$DB_USER" ] && [ -f "$_envf" ] && DB_USER="$(grep -E '^DB_USER=' "$_envf" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    [ -z "$DB_NAME" ] && [ -f "$_envf" ] && DB_NAME="$(grep -E '^DB_NAME=' "$_envf" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    DB_USER="${DB_USER:-postgres}"; DB_NAME="${DB_NAME:-postgres}"

    # Ensure Postgres is up (start just the db service via compose).
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
      log "  starting Postgres (compose up -d db)"
      run "(cd '$PHANSORA_DIR' && docker compose -f '$PHANSORA_COMPOSE' up -d db)"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
      # Wait for readiness (up to ~60s).
      log "  waiting for Postgres to accept connections..."
      ready=0
      for _ in $(seq 1 30); do
        if docker exec "$PG_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; then ready=1; break; fi
        sleep 2
      done
      if [ "$ready" -eq 1 ]; then
        # Make the load idempotent (safe to re-run). On a second run the app is
        # usually up and the DB already populated, which makes an object-level
        # reload flaky. So: stop the app to drop its connections, then drop &
        # recreate the target DB so the load always starts from empty.
        run "(cd '$PHANSORA_DIR' && docker compose -f '$PHANSORA_COMPOSE' stop app >/dev/null 2>&1) || true"
        if [ "$DB_NAME" != "postgres" ]; then
          log "  recreating a clean database '$DB_NAME' (idempotent re-run)"
          # Connect to the maintenance 'postgres' DB so we can drop the target.
          # ON_ERROR_STOP=0 so ALTER on a not-yet-existing DB doesn't abort.
          docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=0 -U "$DB_USER" -d postgres >/dev/null 2>&1 <<SQL || warn "  could not fully recreate '$DB_NAME' — falling back to the dump's --clean"
ALTER DATABASE "$DB_NAME" WITH ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$DB_NAME";
CREATE DATABASE "$DB_NAME" OWNER "$DB_USER";
SQL
        fi
        log "  loading dump into db=$DB_NAME user=$DB_USER"
        if gunzip -c "${SRC}/database.sql.gz" | docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=0 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
          ok "database restored"
        else
          warn "psql load reported errors — review DB state"
        fi
      else
        warn "Postgres never became ready — database NOT loaded. Start it and run: gunzip -c ${SRC}/database.sql.gz | docker exec -i $PG_CONTAINER psql -U $DB_USER -d $DB_NAME"
      fi
    else
      ok "(dry-run) would load database.sql.gz into db=$DB_NAME user=$DB_USER"
    fi
  else
    warn "database.sql.gz not in archive — DB NOT restored"
  fi
else
  log "--- [5/8] Database  (skipped)"
fi

# ---------------------------------------------------------------------------
# 6. systemd units
# ---------------------------------------------------------------------------
log "--- [6/8] systemd units"
if [ -d "${SRC}/systemd" ] || [ "$DRY_RUN" -eq 1 ]; then
  for f in "${SRC}"/systemd/*.service; do
    [ -e "$f" ] || continue
    run "cp -a '$f' /etc/systemd/system/"
    ok "installed $(basename "$f")"
  done
  for d in "${SRC}"/systemd/*.service.d; do
    [ -e "$d" ] || continue
    run "cp -a '$d' /etc/systemd/system/"
    ok "installed drop-in $(basename "$d")"
  done
  run "systemctl daemon-reload"
  # Re-enable units that were enabled on the old box.
  if [ -f "${SRC}/systemd/enabled-state.txt" ]; then
    while IFS=: read -r unit state; do
      unit="$(echo "$unit" | tr -d ' ')"; state="$(echo "$state" | tr -d ' ')"
      [ -n "$unit" ] || continue
      if [ "$state" = "enabled" ]; then
        run "systemctl enable '$unit'"
        ok "enabled $unit (was enabled on source box)"
      else
        log "  $unit was '$state' on source — left as-is"
      fi
    done < "${SRC}/systemd/enabled-state.txt"
  fi
else
  warn "no systemd/ dir in archive"
fi

# ---------------------------------------------------------------------------
# 7. Start the application stack (optional)
# ---------------------------------------------------------------------------
if [ "$START_STACK" -eq 1 ]; then
  log "--- [7/8] Start application stack"
  run "(cd '$PHANSORA_DIR' && docker compose -f '$PHANSORA_COMPOSE' up -d)"
  ok "phansora stack up"
  run "(cd '$PHANSORA_API_DIR' && docker compose -f '$PHANSORA_API_COMPOSE' up -d)"
  ok "phansora-api stack up"
else
  log "--- [7/8] Start application stack  (skipped — pass --stack, or start via systemd)"
fi

# ---------------------------------------------------------------------------
# 8. Crontab (optional)
# ---------------------------------------------------------------------------
if [ "$WITH_CRON" -eq 1 ]; then
  log "--- [8/8] Crontab"
  if [ -f "${SRC}/cron/root-or-user.crontab" ] || [ "$DRY_RUN" -eq 1 ]; then
    run "crontab '${SRC}/cron/root-or-user.crontab'"
    ok "installed crontab for $(id -un)"
  else
    warn "no crontab in archive"
  fi
else
  log "--- [8/8] Crontab  (skipped — pass --with-cron to restore)"
fi

# ---------------------------------------------------------------------------
log "=== Restore finished with $WARN_COUNT warning(s) ==="
cat <<EOF

Next steps to finish bringing the box online:
  1. Load the DB dump BEFORE starting the app, using the PROD compose
     (restore.sh already did this if you didn't pass --skip-db). Then start
     the app last so its migrations no-op:
       (cd $PHANSORA_DIR && docker compose -f docker-compose.prod.yml up -d)
     Verify:  docker exec -it $PG_CONTAINER psql -U <DB_USER> -d <DB_NAME> -c 'select count(*) from users;'
  2. Frontend deps:  (cd $PHANSORA_DIR && npm ci)
  3. API deps: build the venv with Python 3.10 (NOT plain 'python -m venv' —
     CentOS 8 default is 3.6, torch wheels are cp310). See README section
     "API on CentOS Stream 8":
       uv venv --python 3.10 $PHANSORA_API_DIR/.venv && \
         $PHANSORA_API_DIR/.venv/bin/pip install -r $PHANSORA_API_DIR/requirements.txt
  4. Test nginx + reload:   nginx -t && systemctl reload nginx
  5. Point DNS at this box and verify https://www.phansora.com
EOF
[ "$WARN_COUNT" -gt 0 ] && exit 1
exit 0
