#!/bin/bash
# Pre-outage graceful shutdown for the home file server.
#
# Runs daily at 15:45 (root cron) and powers the server off cleanly before
# the ~16:00 scheduled power cut. See README.md for details.
#
# Install:  sudo install -m 0755 scripts/pre-outage-shutdown.sh /usr/local/bin/pre-outage-shutdown.sh
# Schedule: sudo crontab -e  ->  45 15 * * * /usr/local/bin/pre-outage-shutdown.sh
set -uo pipefail

SHARE_ROOT=/srv/data/shared
DATA_MOUNT=/srv/data/
NOTICE="$SHARE_ROOT/!! SERVER SHUTS DOWN AT 15-55 !!.txt"
AVAIL=/run/samba-availability.conf
LOG=/var/log/pre-outage.log

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

cleanup() {
	log "Cleanup triggered - removing notice file."
	rm -f "$NOTICE"
}
trap cleanup EXIT INT TERM

# --- Escape hatch: create this file to cancel today's shutdown ---
if [ -f /run/no-auto-shutdown ] || [ -f /etc/no-auto-shutdown ]; then
	log "Hold file present — shutdown cancelled."
	exit 0
fi

exec 9>/var/lock/pre-outage.lock
flock -n 9 || { log "Already running"; exit 0; }

log "=== T-10: starting pre-outage drill ==="

# 1. Visible warning on the share itself
printf 'This server powers down at 15:55 daily to survive the 16:00 outage.\r\nFinish your copies now.\r\n' > "$NOTICE"

# 2. Warn any logged-in local/SSH users
wall "Server powers off at 15:55 (pre-outage drill). Save your work."

# --- T-5: stop accepting NEW connections ---
sleep $(( 5 * 60 ))
log "=== T-5: closing shares to new connections ==="
echo "available = no" > "$AVAIL"
smbcontrol all reload-config
smbcontrol smbd close-share Shared 2>/dev/null
smbcontrol smbd close-share Personal 2>/dev/null

# --- T-2: report and evict stragglers ---
sleep $(( 3 * 60 ))
log "=== T-2: active sessions below ==="
smbstatus -b >>"$LOG" 2>&1
smbstatus -L >>"$LOG" 2>&1

systemctl stop wsdd-server smbd nmbd
log "Samba and WSDD services stopped"

# --- T-1: flush everything to physical media ---
sleep 60
sync; sync

# Push the drive's own write cache to the platters/NAND
for d in /dev/sd?; do hdparm -F "$d" >/dev/null 2>&1; done

# Remount data volume read-only so nothing can dirty it again
if mountpoint -q "$DATA_MOUNT"; then
	fuser -km "$DATA_MOUNT" 2>/dev/null
	sleep 2
	mount -o remount,ro "$DATA_MOUNT" && log "Data volume now read-only" \
		|| log "WARNING: remount ro failed (files still open)"
fi
sync

log "=== Powering off ==="
sleep 5
/sbin/poweroff
