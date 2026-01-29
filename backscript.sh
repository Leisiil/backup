#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RESTIC SETUP SCRIPT (Public / Generic)
# ==============================================================================
# Dieses Skript konfiguriert Restic Backups für Hetzner Storage Boxen.
# Es erlaubt den Import vorhandener SSH-Keys (z.B. aus Termius).
# ==============================================================================

# --- 1. INTERAKTIVE KONFIGURATION ---
echo "========================================================================"
echo "🔧 RESTIC BACKUP SETUP"
echo "========================================================================"

ask_val() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    if [[ -z "${!var_name:-}" ]]; then
        if [[ -n "$default_val" ]]; then
            read -rp "$prompt_text [$default_val]: " input
            export $var_name="${input:-$default_val}"
        else
            read -rp "$prompt_text: " input
            export $var_name="$input"
        fi
    fi
}

ask_val "STORAGEBOX_USER" "Hetzner StorageBox Username (z.B. u123456)"
ask_val "STORAGEBOX_HOST" "Hetzner Host URL" "${STORAGEBOX_USER}.your-storagebox.de"
ask_val "STORAGEBOX_REMOTE_PATH" "Remote Ordner auf Box" "backups"
ask_val "MOUNT_POINT" "Lokaler Mountpoint" "/mnt/storagebox"

DEFAULT_REPO_NAME="$(hostname -s)"
ask_val "REPO_NAME" "Repository Name (Server Name)" "$DEFAULT_REPO_NAME"
ask_val "CRON_TIME" "Backup Zeitplan (Cron Format)" "0 2 * * *"

# Interne Variablen
RESTIC_DIR="/etc/restic"
PASSFILE="${RESTIC_DIR}/password"
PATHSFILE="${RESTIC_DIR}/paths"
EXCLUDEFILE="${RESTIC_DIR}/exclude"
BACKUP_SCRIPT="/usr/local/bin/restic-backup.sh"
LOGFILE="/var/log/restic.log"
SSH_KEY="/root/.ssh/id_rsa"
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# --- 2. SSH KEY IMPORT / GENERIERUNG ---
echo
echo "[1/6] Prüfe SSH Konfiguration..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "⚠️  Kein SSH-Key unter $SSH_KEY gefunden."
    echo "Wie möchtest du fortfahren?"
    echo "1) Vorhandenen Private Key einfügen (z.B. aus Termius)"
    echo "2) Neuen Key generieren"
    read -rp "Auswahl [1/2]: " key_choice

    if [[ "$key_choice" == "1" ]]; then
        echo "---"
        echo "Bitte kopiere deinen PRIVATE KEY jetzt hier hinein."
        echo "Wenn du fertig bist, drücke ENTER und dann STRG+D."
        echo "---"
        cat > "${SSH_KEY}"
        chmod 600 "${SSH_KEY}"
        
        echo "Bitte kopiere deinen PUBLIC KEY jetzt hier hinein (Ende mit STRG+D):"
        cat > "${SSH_KEY}.pub"
        echo "[+] Keys erfolgreich gespeichert."
    else
        echo "[!] Generiere neuen RSA 4096 Key..."
        ssh-keygen -t rsa -b 4096 -f "${SSH_KEY}" -N "" -q
        echo "[+] Neuer Key erstellt."
    fi
else
    echo "[+] Vorhandener Key gefunden."
fi

# Verbindungstest
echo "[...] Teste Verbindung zur Storage Box..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 -i "${SSH_KEY}" "${STORAGEBOX_USER}@${STORAGEBOX_HOST}" "echo connection_ok" 2>/dev/null | grep -q "connection_ok"; then
    echo "✅ SSH Verbindung steht!"
else
    echo
    echo "❌ SSH VERBINDUNG FEHLGESCHLAGEN"
    echo "Bitte stelle sicher, dass dieser Public Key bei Hetzner hinterlegt ist:"
    echo "------------------------------------------------------------------------"
    cat "${SSH_KEY}.pub"
    echo "------------------------------------------------------------------------"
    exit 1
fi

# --- 3. RESTIC KONFIGURATION ---
echo "[2/6] Erstelle Konfigurationsdateien..."
mkdir -p "${RESTIC_DIR}"
chmod 700 "${RESTIC_DIR}"

if [[ ! -f "${PASSFILE}" ]]; then
    echo "🔐 Bitte lege ein RESTIC PASSWORT fest (für die Verschlüsselung):"
    read -rsp "Passwort: " PW; echo
    read -rsp "Bestätigen: " PW2; echo
    if [[ "$PW" != "$PW2" ]]; then echo "❌ Passwörter ungleich!"; exit 1; fi
    umask 077
    printf "%s" "$PW" > "${PASSFILE}"
    echo "[+] Passwort gespeichert."
fi

if [[ ! -f "${PATHSFILE}" ]]; then
    cat > "${PATHSFILE}" <<EOF
/etc
/root
/home
/var/lib/docker/volumes
/srv
/opt
EOF
    echo "[+] Standard-Pfade erstellt."
fi

if [[ ! -f "${EXCLUDEFILE}" ]]; then
    cat > "${EXCLUDEFILE}" <<EOF
**/cache/**
**/tmp/**
**/.Trash-*/
**/.cache/**
EOF
    echo "[+] Exclude-Liste erstellt."
fi

# --- 4. REPOSITORY INITIALISIEREN ---
echo "[3/6] Initialisiere Repository auf Storage Box..."
mkdir -p "${MOUNT_POINT}"

if ! mountpoint -q "${MOUNT_POINT}"; then
    sshfs "${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_REMOTE_PATH}" "${MOUNT_POINT}" \
      -o IdentityFile="${SSH_KEY}",reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
fi

REPO_PATH="${MOUNT_POINT}/${REPO_NAME}"
mkdir -p "${REPO_PATH}"
export RESTIC_PASSWORD_FILE="${PASSFILE}"

if [[ -f "${REPO_PATH}/config" ]]; then
    echo "[+] Repo existiert bereits."
else
    echo "[+] Initialisiere neues Restic-Repo..."
    restic -r "${REPO_PATH}" init
fi

# --- 5. BACKUP RUNNER SCRIPT ---
echo "[4/6] Erstelle Backup-Skript..."

cat > "${BACKUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export RESTIC_PASSWORD_FILE="${PASSFILE}"
REPO_PATH="${REPO_PATH}"
PATHSFILE="${PATHSFILE}"
EXCLUDEFILE="${EXCLUDEFILE}"
LOGFILE="${LOGFILE}"
MOUNT_POINT="${MOUNT_POINT}"
SSH_KEY="${SSH_KEY}"
STORAGE_CMD="${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_REMOTE_PATH}"

# Auto-Mount falls nötig
if ! mountpoint -q "\${MOUNT_POINT}"; then
  echo "[\$(date -Is)] Remounting..." >> "\${LOGFILE}"
  sshfs "\${STORAGE_CMD}" "\${MOUNT_POINT}" \\
    -o IdentityFile="\${SSH_KEY}",reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \\
    2>> "\${LOGFILE}" || true
  
  if ! mountpoint -q "\${MOUNT_POINT}"; then
    echo "[\$(date -Is)] CRITICAL: Mount fail." >> "\${LOGFILE}"
    exit 1
  fi
fi

echo "[\$(date -Is)] Backup Start..." >> "\${LOGFILE}"
restic -r "\${REPO_PATH}" backup \$(cat "\${PATHSFILE}") --exclude-file="\${EXCLUDEFILE}" >> "\${LOGFILE}" 2>&1
restic -r "\${REPO_PATH}" forget --keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY} --keep-monthly ${KEEP_MONTHLY} --prune >> "\${LOGFILE}" 2>&1
restic -r "\${REPO_PATH}" check >> "\${LOGFILE}" 2>&1
echo "[\$(date -Is)] Backup Ende." >> "\${LOGFILE}"
EOF

chmod +x "${BACKUP_SCRIPT}"

# --- 6. CRONJOB ---
echo "[5/6] Erstelle Cronjob..."
CRON_FILE="/etc/cron.d/restic-backup"
cat > "${CRON_FILE}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${CRON_TIME} root ${BACKUP_SCRIPT}
EOF
chmod 644 "${CRON_FILE}"

echo "========================================================================"
echo "✅ SETUP ABGESCHLOSSEN"
echo "========================================================================"
echo "Skript: $BACKUP_SCRIPT"
echo "Log:    $LOGFILE"
echo "Repo:   $REPO_PATH"
echo "------------------------------------------------------------------------"
echo "Erster Testlauf mit: $BACKUP_SCRIPT"
