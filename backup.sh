#!/usr/bin/env bash
#
# backup.sh — full production backup for the Phansora stack, built for moving
# to a new box. Captures everything needed to stand the site back up:
#
#   1. Site code under $WWW_DIR (phansora + phansora-api), incl. .env secrets
#   2. The Postgres database  (logical pg_dump from the running container —
#      the data lives in a Docker named volume, so a file tar would miss it)
#   3. Docker named volumes    (e.g. phansora-api "media")
#   4. systemd unit files      (phansora / phansora-api / phansora-book-worker,
#                               plus their .d drop-in dirs)
#   5. nginx configuration     (/etc/nginx)
#   6. TLS certificates        (/etc/letsencrypt — the site is HTTPS)
#   7. Crontabs                (root + invoking user)
#   8. Environment inventory   (docker versions, running containers, os-release)
#
# Design: fail-soft. A missing path is a warning, not a fatal error, so a
# partial-but-useful backup still completes. Exit code is non-zero if any
# component warned, so cron can alert you.
#
# Usage:   sudo ./backup.sh            # uses ./backup.conf if present
#          sudo ./backup.sh -c /path/to/backup.conf
#
# Restore notes live in README.md.

set -u -o pipefail

# ---------------------------------------------------------------------------
# Locate self + load config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/backup.conf"

while getopts "c:h" opt; do
  case "$opt" in
    c) CONF_FILE="$OPTARG" ;;
    h) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "usage: $0 [-c backup.conf]" >&2; exit 2 ;;
  esac
done

# ---- Defaults (overridden by backup.conf) --------------------------------
WWW_DIR="/var/www"
PHANSORA_DIR=""
PHANSORA_API_DIR=""
SYSTEMD_UNITS="phansora.service phansora-api.service phansora-book-worker.service"
NGINX_DIR="/etc/nginx"
LETSENCRYPT_DIR="/etc/letsencrypt"
PG_CONTAINER="phansora_postgres"
DB_USER=""
DB_NAME=""
VOLUME_MATCH="media"
BACKUP_ROOT="/var/backups/phansora"
RETENTION_DAYS=14
# Derived/regenerable data — nothing here is source-of-truth, so it is dropped
# to keep the archive small. Notably NOT excluded: voices/ (user-uploaded voice
# clone reference clips — unrecoverable if lost) and history/ (per-user event
# logs). hf-cache is the HuggingFace model download cache and is by far the
# largest thing on the box (~230M); it re-fetches automatically on first use.
EXCLUDES="node_modules .venv venv __pycache__ .pytest_cache .cache tmp .tmp_uploads output_audio output_txt hf-cache */data/chrono_origin/cache"
# Overwrite mode: when 1, every run writes to ONE fixed archive (no timestamp),
# replacing the previous one in place — so hourly backups never accumulate.
# RETENTION_DAYS is irrelevant in this mode (there is only ever one file).
SINGLE_FILE=0
SINGLE_FILE_NAME="phansora-backup-latest"

if [ -f "$CONF_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONF_FILE"
else
  echo "note: no config file at $CONF_FILE — using built-in defaults" >&2
fi

# Derive project dirs if the config didn't set them explicitly.
PHANSORA_DIR="${PHANSORA_DIR:-${WWW_DIR}/phansora}"
PHANSORA_API_DIR="${PHANSORA_API_DIR:-${WWW_DIR}/phansora-api}"

# Which directories under WWW_DIR to actually archive. We deliberately do NOT
# tar the whole WWW_DIR tree — it can contain huge unrelated things (e.g. a
# CosyVoice model checkout). Override PROJECT_DIRS in backup.conf to add more.
PROJECT_DIRS="${PROJECT_DIRS:-${PHANSORA_DIR} ${PHANSORA_API_DIR}}"

# ---------------------------------------------------------------------------
# Setup: timestamped staging dir + logging
# ---------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_S="$(hostname -s 2>/dev/null || echo host)"
if [ "${SINGLE_FILE:-0}" -eq 1 ]; then
  # Fixed name → one archive + one log that get overwritten every run.
  NAME="$SINGLE_FILE_NAME"
  LOG="${BACKUP_ROOT}/${NAME}.log"
else
  NAME="phansora-backup-${HOSTNAME_S}-${STAMP}"
  LOG="${BACKUP_ROOT}/${NAME}.log"
fi
WORK="${BACKUP_ROOT}/.staging/${NAME}"
WARN_COUNT=0

mkdir -p "$BACKUP_ROOT" || { echo "FATAL: cannot create $BACKUP_ROOT (are you root?)" >&2; exit 1; }

# Prevent overlapping runs (an hourly cron can fire before a slow run finishes).
# Non-blocking: if another backup holds the lock, exit quietly with success.
LOCK_FILE="${BACKUP_ROOT}/.backup.lock"
exec 9>"$LOCK_FILE" 2>/dev/null || true
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  echo "note: another backup is already running (lock: $LOCK_FILE) — skipping this run" >&2
  exit 0
fi

# In single-file mode start the staging dir and log fresh each run.
[ "${SINGLE_FILE:-0}" -eq 1 ] && rm -rf "$WORK"
mkdir -p "$WORK" || { echo "FATAL: cannot create $WORK (are you root?)" >&2; exit 1; }

# Tee all output to the log. Overwrite (not append) in single-file mode so the
# log doesn't grow without bound; append in timestamped mode (one log per run).
[ "${SINGLE_FILE:-0}" -eq 1 ] && : > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "[$(date +%H:%M:%S)]   ok  - $*"; }
warn() { echo "[$(date +%H:%M:%S)]  WARN - $*"; WARN_COUNT=$((WARN_COUNT + 1)); }

log "=== Phansora backup started: $NAME ==="
log "config: $CONF_FILE"
log "staging: $WORK"
[ "$(id -u)" -eq 0 ] || warn "not running as root — /etc, letsencrypt, docker volumes and root crontab may be unreadable"

# Build tar --exclude args once.
EXCLUDE_ARGS=()
for e in $EXCLUDES; do EXCLUDE_ARGS+=(--exclude="$e"); done

# ---------------------------------------------------------------------------
# 1. Site code — ONLY the project dirs (secrets included, heavy dirs excluded).
#    Packed relative to dirname(WWW_DIR) so members are 'www/phansora/...' etc.,
#    matching what restore.sh expects (it extracts with --strip-components=1).
# ---------------------------------------------------------------------------
log "--- [1/8] Site code: ${PROJECT_DIRS}"
WWW_PARENT="$(dirname "$WWW_DIR")"
REL_DIRS=()
for d in $PROJECT_DIRS; do
  if [ ! -d "$d" ]; then
    warn "project dir missing, skipping: $d"
    continue
  fi
  # Path relative to WWW_PARENT (e.g. /var/www/phansora -> www/phansora).
  rel="${d#"${WWW_PARENT}/"}"
  if [ "$rel" = "$d" ]; then
    warn "project dir '$d' is not under '$WWW_PARENT' — skipping (would break restore layout)"
    continue
  fi
  REL_DIRS+=("$rel")
done

if [ "${#REL_DIRS[@]}" -gt 0 ]; then
  if tar czf "${WORK}/www.tar.gz" "${EXCLUDE_ARGS[@]}" -C "$WWW_PARENT" "${REL_DIRS[@]}"; then
    ok "archived ${REL_DIRS[*]} -> www.tar.gz ($(du -h "${WORK}/www.tar.gz" | cut -f1))"
    # Explicitly confirm the .env secret files came along — easy to lose these.
    # Both apps use a single .env (not .env.production / .env.local).
    for envf in "${PHANSORA_DIR}/.env" "${PHANSORA_API_DIR}/.env"; do
      [ -f "$envf" ] && ok "  captured secrets: $envf" || warn "  expected env file missing: $envf"
    done
  else
    warn "tar of project dirs failed"
  fi
else
  warn "no project dirs to archive — check PROJECT_DIRS / WWW_DIR in backup.conf"
fi

# ---------------------------------------------------------------------------
# 2. Postgres database (logical dump from the running container)
# ---------------------------------------------------------------------------
log "--- [2/8] Postgres database (container: $PG_CONTAINER)"
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    # Fill in creds from phansora/.env if not set in config.
    _envf="${PHANSORA_DIR}/.env"
    [ -z "$DB_USER" ] && [ -f "$_envf" ] && DB_USER="$(grep -E '^DB_USER=' "$_envf" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    [ -z "$DB_NAME" ] && [ -f "$_envf" ] && DB_NAME="$(grep -E '^DB_NAME=' "$_envf" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    DB_USER="${DB_USER:-postgres}"
    DB_NAME="${DB_NAME:-postgres}"
    log "  pg_dump user=$DB_USER db=$DB_NAME"
    # --clean --if-exists makes the dump idempotent to restore onto a fresh DB.
    if docker exec "$PG_CONTAINER" pg_dump -U "$DB_USER" --clean --if-exists "$DB_NAME" \
         | gzip > "${WORK}/database.sql.gz"; then
      if [ -s "${WORK}/database.sql.gz" ]; then
        ok "database dumped -> database.sql.gz ($(du -h "${WORK}/database.sql.gz" | cut -f1))"
      else
        warn "pg_dump produced an empty file — check DB_USER/DB_NAME"
      fi
    else
      warn "pg_dump failed (wrong creds, or DB not ready)"
    fi
  else
    warn "container '$PG_CONTAINER' not running — DATABASE NOT BACKED UP. Start the stack or fix PG_CONTAINER."
  fi
else
  warn "docker not found — cannot dump database"
fi

# ---------------------------------------------------------------------------
# 3. Docker named volumes (raw tar via a throwaway alpine container)
# ---------------------------------------------------------------------------
log "--- [3/8] Docker named volumes (match: $VOLUME_MATCH)"
if command -v docker >/dev/null 2>&1; then
  matched=0
  for vol in $(docker volume ls -q 2>/dev/null); do
    keep=0
    for m in $VOLUME_MATCH; do case "$vol" in *"$m"*) keep=1 ;; esac; done
    [ "$keep" -eq 1 ] || continue
    matched=1
    if docker run --rm -v "${vol}:/data:ro" -v "${WORK}:/backup" alpine \
         tar czf "/backup/volume-${vol}.tar.gz" -C /data . 2>/dev/null; then
      ok "volume '$vol' -> volume-${vol}.tar.gz ($(du -h "${WORK}/volume-${vol}.tar.gz" 2>/dev/null | cut -f1))"
    else
      warn "failed to archive volume '$vol'"
    fi
  done
  [ "$matched" -eq 1 ] || warn "no docker volumes matched '$VOLUME_MATCH' (nothing archived)"
else
  warn "docker not found — cannot archive named volumes"
fi

# ---------------------------------------------------------------------------
# 4. systemd unit files (+ enabled state + drop-ins)
# ---------------------------------------------------------------------------
log "--- [4/8] systemd units: $SYSTEMD_UNITS"
mkdir -p "${WORK}/systemd"
for unit in $SYSTEMD_UNITS; do
  found=0
  for base in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    if [ -f "${base}/${unit}" ]; then
      cp -a "${base}/${unit}" "${WORK}/systemd/" && found=1
    fi
    # drop-in directory (e.g. phansora.service.d/override.conf)
    if [ -d "${base}/${unit}.d" ]; then
      cp -a "${base}/${unit}.d" "${WORK}/systemd/" && found=1
    fi
  done
  if [ "$found" -eq 1 ]; then
    ok "copied unit: $unit"
    # Record whether it's enabled so you can re-enable on the new box.
    if command -v systemctl >/dev/null 2>&1; then
      state="$(systemctl is-enabled "$unit" 2>/dev/null || echo unknown)"
      echo "${unit}: ${state}" >> "${WORK}/systemd/enabled-state.txt"
    fi
  else
    warn "unit not found on disk: $unit"
  fi
done

# ---------------------------------------------------------------------------
# 5. nginx configuration
# ---------------------------------------------------------------------------
log "--- [5/8] nginx config: $NGINX_DIR"
if [ -d "$NGINX_DIR" ]; then
  if tar czf "${WORK}/nginx.tar.gz" -C "$(dirname "$NGINX_DIR")" "$(basename "$NGINX_DIR")"; then
    ok "archived $NGINX_DIR -> nginx.tar.gz"
  else
    warn "tar of $NGINX_DIR failed"
  fi
else
  warn "$NGINX_DIR does not exist (nginx not installed here, or different path)"
fi

# ---------------------------------------------------------------------------
# 6. TLS certificates (Let's Encrypt) — site is HTTPS
# ---------------------------------------------------------------------------
log "--- [6/8] TLS certificates: $LETSENCRYPT_DIR"
if [ -d "$LETSENCRYPT_DIR" ]; then
  # -h dereferences the live/ symlinks so archive/ private keys travel too.
  if tar czhf "${WORK}/letsencrypt.tar.gz" -C "$(dirname "$LETSENCRYPT_DIR")" "$(basename "$LETSENCRYPT_DIR")"; then
    ok "archived $LETSENCRYPT_DIR -> letsencrypt.tar.gz"
  else
    warn "tar of $LETSENCRYPT_DIR failed"
  fi
else
  warn "$LETSENCRYPT_DIR does not exist — if you use certbot, certs are NOT backed up"
fi

# ---------------------------------------------------------------------------
# 7. Crontabs
# ---------------------------------------------------------------------------
log "--- [7/8] Crontabs"
mkdir -p "${WORK}/cron"
crontab -l >"${WORK}/cron/root-or-user.crontab" 2>/dev/null \
  && ok "saved crontab for $(id -un)" || warn "no crontab for $(id -un) (or none set)"
[ -d /etc/cron.d ] && cp -a /etc/cron.d "${WORK}/cron/cron.d" 2>/dev/null && ok "copied /etc/cron.d"

# ---------------------------------------------------------------------------
# 8. Environment inventory (for rebuilding the box the same way)
# ---------------------------------------------------------------------------
log "--- [8/8] Environment inventory"
{
  echo "# Captured $(date) on $(hostname -f 2>/dev/null || hostname)"
  echo; echo "## os-release"; cat /etc/os-release 2>/dev/null
  echo; echo "## docker version"; docker --version 2>/dev/null
  echo "## docker compose version"; docker compose version 2>/dev/null || docker-compose --version 2>/dev/null
  echo; echo "## running containers"; docker ps 2>/dev/null
  echo; echo "## docker volumes"; docker volume ls 2>/dev/null
  echo; echo "## docker images"; docker images 2>/dev/null
  echo; echo "## nginx"; command -v nginx >/dev/null 2>&1 && nginx -v 2>&1 || echo "nginx NOT installed"
  echo; echo "## firewall (firewalld)"; command -v firewall-cmd >/dev/null 2>&1 && { firewall-cmd --state 2>&1; firewall-cmd --list-all 2>/dev/null; } || echo "firewalld not present"
  echo; echo "## firewall (ufw)"; command -v ufw >/dev/null 2>&1 && ufw status verbose 2>/dev/null || echo "ufw not present"
  echo; echo "## nginx -T (effective config)"; nginx -T 2>/dev/null | head -200
} > "${WORK}/inventory.txt" 2>&1
ok "wrote inventory.txt"

# ---------------------------------------------------------------------------
# Finalize: checksums, manifest, single archive, retention prune
# ---------------------------------------------------------------------------
log "--- Finalizing"
( cd "$WORK" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
    | xargs -0 sha256sum > SHA256SUMS ) && ok "wrote SHA256SUMS ($(grep -c . "${WORK}/SHA256SUMS" 2>/dev/null || echo 0) files)" \
    || warn "checksum generation had errors"

cat > "${WORK}/MANIFEST.txt" <<EOF
Phansora production backup
==========================
Name      : $NAME
Created   : $(date)
Host      : $(hostname -f 2>/dev/null || hostname)
WWW_DIR   : $WWW_DIR
Warnings  : $WARN_COUNT

Contents:
  www.tar.gz          Site code + .env secrets (excludes: $EXCLUDES)
  database.sql.gz     Postgres logical dump (restore: gunzip | psql)
  volume-*.tar.gz     Docker named volumes (e.g. media)
  systemd/            Unit files + enabled-state.txt
  nginx.tar.gz        /etc/nginx
  letsencrypt.tar.gz  TLS certs (symlinks dereferenced)
  cron/               Crontabs
  inventory.txt       Versions / running containers for reference
  SHA256SUMS          Checksums of the above

See README.md in the backup-cron folder for restore steps.
EOF
ok "wrote MANIFEST.txt"

# Roll the staging dir into one archive next to the log, then clean staging.
# Write to a .tmp first and atomically mv into place, so a crash mid-write (or a
# dashboard download in flight) never sees a half-written archive.
FINAL="${BACKUP_ROOT}/${NAME}.tar.gz"
FINAL_TMP="${FINAL}.tmp.$$"
if tar czf "$FINAL_TMP" -C "$(dirname "$WORK")" "$(basename "$WORK")" && mv -f "$FINAL_TMP" "$FINAL"; then
  ok "final archive: $FINAL ($(du -h "$FINAL" | cut -f1))"
  rm -rf "$WORK"
else
  warn "could not roll up staging dir; leaving it at $WORK"
  rm -f "$FINAL_TMP"
fi

# Metadata sidecar (read by the phansora admin dashboard "Storage → Backup"
# panel to show last-run time / status without needing to read the archive).
FINAL_SHA=""
[ -f "$FINAL" ] && command -v sha256sum >/dev/null 2>&1 && FINAL_SHA="$(sha256sum "$FINAL" | cut -d' ' -f1)"
FINAL_BYTES="$([ -f "$FINAL" ] && stat -c %s "$FINAL" 2>/dev/null || echo 0)"
BACKUP_STATUS="$([ "$WARN_COUNT" -eq 0 ] && echo ok || echo warn)"
cat > "${BACKUP_ROOT}/${NAME}.json" <<EOF
{
  "name": "${NAME}",
  "file": "${NAME}.tar.gz",
  "host": "$(hostname -f 2>/dev/null || hostname)",
  "created": "$(date --iso-8601=seconds 2>/dev/null || date)",
  "created_epoch": $(date +%s),
  "size_bytes": ${FINAL_BYTES},
  "warnings": ${WARN_COUNT},
  "status": "${BACKUP_STATUS}",
  "sha256": "${FINAL_SHA}",
  "single_file": ${SINGLE_FILE:-0}
}
EOF
ok "wrote ${NAME}.json (status=${BACKUP_STATUS})"

# Retention prune — only meaningful for timestamped mode. In single-file mode
# there is exactly one archive, so there is nothing to prune.
if [ "${SINGLE_FILE:-0}" -ne 1 ] && [ "${RETENTION_DAYS:-0}" -gt 0 ]; then
  log "pruning backups older than ${RETENTION_DAYS} days in $BACKUP_ROOT"
  find "$BACKUP_ROOT" -maxdepth 1 -name 'phansora-backup-*.tar.gz' -type f -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null || true
  find "$BACKUP_ROOT" -maxdepth 1 -name 'phansora-backup-*.log'    -type f -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
log "=== Backup finished with $WARN_COUNT warning(s) ==="
if [ "$WARN_COUNT" -gt 0 ]; then
  log "Review the WARN lines above — some components may be incomplete."
  exit 1
fi
exit 0
