#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RESTIC SETUP - LIGHT VERSION (No SSH Key Gen / No Cron)
# ==============================================================================

echo "========================================================================"
echo "🔧 RESTIC SETUP (Core Only)"
echo "========================================================================"

ask_val() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    read -rp "$prompt_text [$default_val]: " input
    export $var_name="${input:-$default_val}"
}

# 1. Konfiguration abfragen
ask_val "STORAGEBOX_USER" "Hetzner StorageBox Username"
ask_val "STORAGEBOX_HOST" "Hetzner Host URL" "${STORAGEBOX_USER}.your-storagebox.de"
ask_val "STORAGEBOX_REMOTE_PATH" "Remote Ordner auf Box" "backups"
ask_val "MOUNT_POINT" "Lokaler Mountpoint" "/mnt/storagebox"
ask_val "REPO_NAME" "Repository Name" "$(hostname -s)"

# Interne Pfade
RESTIC_DIR="/etc/restic"
PASSFILE="${RESTIC_DIR}/password"
PATHSFILE="${RESTIC_DIR}/paths"
BACKUP_SCRIPT="/usr/local/bin/restic-backup.sh"
LOGFILE="/var/log/restic.log"

# 2. Config Verzeichnis erstellen
mkdir -p "${RESTIC_DIR}"
chmod 700 "${RESTIC_DIR}"

# Restic Passwort setzen
if [[ ! -f "${PASSFILE}" ]]; then
    echo "🔐 Restic Repo Passwort festlegen:"
    read -rsp "Passwort: " PW; echo
    printf "%s" "$PW" > "${PASSFILE}"
    chmod 600 "${PASSFILE}"
fi

# Pfade festlegen
if [[ ! -f "${PATHSFILE}" ]]; then
    echo "/etc
/root
/home
/var/lib/docker/volumes" > "${PATHSFILE}"
fi

# 3. Mount & Repo Init
echo "[...] Erstelle Mountpoint ${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}"

echo "⚠️  HINWEIS: Falls kein Key hinterlegt ist, fragt das System jetzt nach dem Storage-Box Passwort."
if ! mountpoint -q "${MOUNT_POINT}"; then
    sshfs "${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_REMOTE_PATH}" "${MOUNT_POINT}" \
      -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
fi

REPO_PATH="${MOUNT_POINT}/${REPO_NAME}"
mkdir -p "${REPO_PATH}"
export RESTIC_PASSWORD_FILE="${PASSFILE}"

if [[ -f "${REPO_PATH}/config" ]]; then
    echo "[+] Repo existiert bereits."
else
    echo "[+] Initialisiere Restic-Repo..."
    restic -r "${REPO_PATH}" init
fi

# 4. Backup-Runner Skript erstellen (Ohne Cronjob-Installation)
cat > "${BACKUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export RESTIC_PASSWORD_FILE="${PASSFILE}"
REPO_PATH="${REPO_PATH}"
LOGFILE="${LOGFILE}"

echo "[\$(date -Is)] Backup Start..." >> "\${LOGFILE}"
restic -r "\${REPO_PATH}" backup \$(cat "${PATHSFILE}") >> "\${LOGFILE}" 2>&1
restic -r "\${REPO_PATH}" forget --keep-daily 7 --prune >> "\${LOGFILE}" 2>&1
echo "[\$(date -Is)] Done." >> "\${LOGFILE}"
EOF

chmod +x "${BACKUP_SCRIPT}"

echo "========================================================================"
echo "✅ SETUP FERTIG"
echo "------------------------------------------------------------------------"
echo "Backup-Skript erstellt unter: ${BACKUP_SCRIPT}"
echo "Manueller Testlauf: ${BACKUP_SCRIPT}"
