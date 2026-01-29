#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RESTIC SETUP SCRIPT (Public / Generic)
# ==============================================================================
# This script sets up Restic backup with Hetzner Storage Box.
# It handles SSH keys, repository initialization, and cronjob creation.
#
# Usage: ./setup-restic.sh
# ==============================================================================

# --- 1. INTERACTIVE CONFIGURATION ---
echo "========================================================================"
echo "🔧 RESTIC BACKUP SETUP"
echo "========================================================================"

# Function to prompt for input if variable is not set
ask_val() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    
    # Check if var is already set via ENV
    if [[ -z "${!var_name:-}" ]]; then
        if [[ -n "$default_val" ]]; then
            read -rp "$prompt_text [$default_val]: " input
            export $var_name="${input:-$default_val}"
        else
            read -rp "$prompt_text: " input
            export $var_name="$input"
        fi
    fi
    
    # Validate
    if [[ -z "${!var_name}" ]]; then
        echo "❌ Error: $var_name is required."
        exit 1
    fi
}

# Ask for Credentials
ask_val "STORAGEBOX_USER" "Hetzner StorageBox Username (e.g., u123456)"
ask_val "STORAGEBOX_HOST" "Hetzner Host URL" "${STORAGEBOX_USER}.your-storagebox.de"
ask_val "STORAGEBOX_REMOTE_PATH" "Remote Path on Box" "backups"
ask_val "MOUNT_POINT" "Local Mount Point" "/mnt/storagebox"

# Ask for Repo Name
DEFAULT_REPO_NAME="$(hostname -s)"
ask_val "REPO_NAME" "Repository Name (Server Name)" "$DEFAULT_REPO_NAME"

# Ask for Cron Time
ask_val "CRON_TIME" "Backup Schedule (Cron format)" "0 2 * * *"

echo
echo "📝 CONFIG SUMMARY:"
echo "   User:   $STORAGEBOX_USER"
echo "   Host:   $STORAGEBOX_HOST"
echo "   Path:   $STORAGEBOX_REMOTE_PATH"
echo "   Mount:  $MOUNT_POINT"
echo "   Repo:   $REPO_NAME"
echo "========================================================================"
echo

# --- INTERNAL VARS ---
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

# --- 2. SSH KEY CHECK ---
echo "[1/6] Checking SSH configuration..."

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "[!] No SSH key found. Generating RSA 4096 key..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY}" -N "" -q
    echo "[+] Key generated."
fi

# Connection Test
echo "[...] Testing connection to ${STORAGEBOX_USER}@${STORAGEBOX_HOST}..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 -i "${SSH_KEY}" "${STORAGEBOX_USER}@${STORAGEBOX_HOST}" "echo connection_ok" 2>/dev/null | grep -q "connection_ok"; then
    echo "✅ SSH connection successful."
else
    echo
    echo "❌ SSH CONNECTION FAILED"
    echo "Please copy the following Public Key to your Hetzner Storage Box (.ssh/authorized_keys):"
    echo "------------------------------------------------------------------------"
    cat "${SSH_KEY}.pub"
    echo "------------------------------------------------------------------------"
    echo "After adding the key, run this script again."
    exit 1
fi

# --- 3. RESTIC CONFIG FILES ---
echo "[2/6] Setting up config files..."
mkdir -p "${RESTIC_DIR}"
chmod 700 "${RESTIC_DIR}"

# Password
if [[ ! -f "${PASSFILE}" ]]; then
    echo
    echo "🔐 Please set a secure RESTIC REPOSITORY PASSWORD."
    echo "Warning: Store this password in a safe place (Bitwarden/Keepass)."
    echo "If you lose this password, your backups are lost forever."
    read -rsp "Enter Password: " PW; echo
    read -rsp "Confirm Password: " PW2; echo
    
    if [[ "$PW" != "$PW2" ]]; then
        echo "❌ Passwords do not match!"
        exit 1
    fi
    
    umask 077
    printf "%s" "$PW" > "${PASSFILE}"
    chmod 600 "${PASSFILE}"
    echo "[+] Password saved to ${PASSFILE}"
else
    echo "[+] Password file already exists."
fi

# Paths
if [[ ! -f "${PATHSFILE}" ]]; then
    cat > "${PATHSFILE}" <<EOF
/etc
/root
/home
/var/lib/docker/volumes
/srv
/opt
EOF
    chmod 600 "${PATHSFILE}"
    echo "[+] Default paths file created."
fi

# Excludes
if [[ ! -f "${EXCLUDEFILE}" ]]; then
    cat > "${EXCLUDEFILE}" <<EOF
**/cache/**
**/tmp/**
**/.Trash-*/
**/.cache/**
EOF
    chmod 600 "${EXCLUDEFILE}"
    echo "[+] Exclude file created."
fi

# --- 4. INIT REPO ---
echo "[3/6] Initializing Repository..."
mkdir -p "${MOUNT_POINT}"

# Check mount
if ! mountpoint -q "${MOUNT_POINT}"; then
    sshfs "${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_REMOTE_PATH}" "${MOUNT_POINT}" \
      -o IdentityFile="${SSH_KEY}",reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
fi

REPO_PATH="${MOUNT_POINT}/${REPO_NAME}"
mkdir -p "${REPO_PATH}"
export RESTIC_PASSWORD_FILE="${PASSFILE}"

if [[ -f "${REPO_PATH}/config" ]]; then
    echo "[+] Repository already exists at ${REPO_PATH}"
else
    echo "[+] Initializing NEW repository at ${REPO_PATH}..."
    restic -r "${REPO_PATH}" init
fi

# --- 5. BACKUP SCRIPT GENERATION ---
echo "[4/6] Generating Backup Runner Script..."

cat > "${BACKUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Load Config
export RESTIC_PASSWORD_FILE="${PASSFILE}"
REPO_PATH="${REPO_PATH}"
PATHSFILE="${PATHSFILE}"
EXCLUDEFILE="${EXCLUDEFILE}"
LOGFILE="${LOGFILE}"
MOUNT_POINT="${MOUNT_POINT}"
SSH_KEY="${SSH_KEY}"
STORAGE_CMD="${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_REMOTE_PATH}"

# === AUTO-MOUNT CHECK ===
if ! mountpoint -q "\${MOUNT_POINT}"; then
  echo "[\$(date -Is)] Mount missing. Attempting remount..." >> "\${LOGFILE}"
  sshfs "\${STORAGE_CMD}" "\${MOUNT_POINT}" \\
    -o IdentityFile="\${SSH_KEY}",reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \\
    2>> "\${LOGFILE}" || true
  
  if ! mountpoint -q "\${MOUNT_POINT}"; then
    echo "[\$(date -Is)] CRITICAL: Remount failed. Aborting." >> "\${LOGFILE}"
    exit 1
  fi
  echo "[\$(date -Is)] Remount successful." >> "\${LOGFILE}"
fi

# === BACKUP ===
echo "[\$(date -Is)] Starting Backup..." >> "\${LOGFILE}"
restic -r "\${REPO_PATH}" backup \$(cat "\${PATHSFILE}") --exclude-file="\${EXCLUDEFILE}" >> "\${LOGFILE}" 2>&1

# === MAINTENANCE ===
echo "[\$(date -Is)] Pruning old snapshots..." >> "\${LOGFILE}"
restic -r "\${REPO_PATH}" forget \\
  --keep-daily ${KEEP_DAILY} \\
  --keep-weekly ${KEEP_WEEKLY} \\
  --keep-monthly ${KEEP_MONTHLY} \\
  --prune >> "\${LOGFILE}" 2>&1

# === CHECK ===
echo "[\$(date -Is)] Health check..." >> "\${LOGFILE}"
restic -r "\${REPO_PATH}" check >> "\${LOGFILE}" 2>&1
echo "[\$(date -Is)] FINISHED." >> "\${LOGFILE}"
EOF

chmod +x "${BACKUP_SCRIPT}"

# --- 6. CRON INSTALLATION ---
echo "[5/6] Installing Cronjob..."
CRON_FILE="/etc/cron.d/restic-backup"

cat > "${CRON_FILE}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${CRON_TIME} root ${BACKUP_SCRIPT}
EOF
chmod 644 "${CRON_FILE}"

echo
echo "========================================================================"
echo "✅ SETUP COMPLETE"
echo "========================================================================"
echo "Your server is now configured for automated backups."
echo "Backup Script: $BACKUP_SCRIPT"
echo "Log File:      $LOGFILE"
echo "Repo Location: $REPO_PATH"
echo
echo "Test run command:"
echo "$BACKUP_SCRIPT"
