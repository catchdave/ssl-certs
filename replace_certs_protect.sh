#!/bin/bash
# This file renews SSL certificates on a "Unifi Protect Cloud Key+ Gen 2" that have already been copied over
# from my "create_ssl_certs.sh" script.
#
# Caveat: You will need to run this again (with --repair) after UniFi OS / Protect updates, since the
#         config files under /usr/share can be rewritten. Verified on UniFi OS 5.1.x / Protect 7.2.x.
#
# IMPORTANT: Do NOT point Protect's "deviceCrt"/"deviceKey" at your public certificate. Cameras pin the
#            console's device certificate when they are adopted and verify firmware downloads (port 7444)
#            against it. A rotating public cert (e.g. Let's Encrypt) breaks every camera firmware update
#            with "Mismatched certs" / TRANSFER_FAILED on the camera side. Only the "crt"/"key" entries
#            (web UI / RTSPS) are safe to change. An earlier version of this script got that wrong.
#
# Prep: Add sudo perms to run this script for the user that executes this script, via visudo:
#       your_user_name ALL=NOPASSWD:/root/replace_certs_protect.sh

# Constants
TARGET=/etc/ssl/private
CORE_CONFIG=/usr/share/unifi-core/app/config/default.yaml  # Pre-3.1, this was config.yaml
PROTECT_CONFIG=/usr/share/unifi-protect/app/config/default.json # Pre 3.2, this was config.json
BACKUP_DIR=/root/ssl_backups
DATE=$(date '+%Y-%m-%d')
REPAIR=false

# Functions
# ============================
info() { echo "$0: [INFO] $1"; }
error() { echo "$0: [ERROR] $1"; }
error_exit() { echo "$0: [ERROR] $1"; exit 1; }
backup_config() {
    backup_file="$BACKUP_DIR/$(basename $1).$DATE"
    if [ ! -f "$backup_file" ]; then
        cp "$1" "$backup_file" || error_exit "Could not backup $1"
        echo "$0: [INFO] Backed up '$1' to: $backup_file"
    else
        echo "$0: [WARN] Not saving copy of '$1' since a file already exists: $backup_file"
    fi
}
usage() {
    echo "Copies over SSL certs from /tmp and updates (or repairs) config files to point to them"
    echo ""
    echo "USAGE: $0 [--repair] [--help]"
    echo "  -r, --repair    Only update/repair the config files to point to the new SSL certs"
    echo "  -h, --help      Display this help message"
}
# ============================

# Check args
while [[ $# -gt 0 ]]; do
  case $1 in
    -r|--repair)
      REPAIR=true
      shift # past argument
      ;;
    -h|--help)
      usage
      exit 1
      ;;
    -*|--*)
      echo "[$0] Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

# Verify root
if [ "$EUID" -ne 0 ]; then
  error_exit "This script needs to run as root"
fi

# Verify new certificates were copied over before running.
if [[ "$REPAIR" != "true" ]]; then
    if [[ ! -f /tmp/fullchain.pem || ! -f /tmp/privkey.pem ]]; then
        error_exit "No certificate files found in /tmp. Aborting."
    fi
fi

# Backup
info "Backing up old certs and config"
mkdir -p "$BACKUP_DIR"
backup_config "$TARGET/unifi-core.crt"
backup_config "$TARGET/unifi-core.key"
backup_config $CORE_CONFIG
backup_config $PROTECT_CONFIG

# Update certs unless only repairing
if [[ "$REPAIR" != "true" ]]; then
    info "Replacing certificates"
    mv /tmp/fullchain.pem "$TARGET/unifi-core.crt" || error_exit "Error replacing fullchain/unifi-core.crt"
    mv /tmp/privkey.pem "$TARGET/unifi-core.key" || error_exit "Error replacing privkey/unifi-core.key"
    chown root:root "$TARGET/unifi-core.crt" "$TARGET/unifi-core.key"
    chmod o+r "$TARGET/unifi-core.crt" "$TARGET/unifi-core.key"  # unifi-protect user needs to access
fi

# Modifying config to point to new certs
if [[ "$REPAIR" == "true" ]]; then
    info "Repairing config files"
else
    info "Modifying config files to point to new certs"
fi
sed -i "s#crt: '/data/unifi-core/config/unifi-core.crt'#crt: '/etc/ssl/private/unifi-core.crt'#" $CORE_CONFIG
sed -i "s#key: '/data/unifi-core/config/unifi-core.key'#key: '/etc/ssl/private/unifi-core.key'#" $CORE_CONFIG
# Only the web UI / RTSPS cert. Leave "deviceCrt"/"deviceKey" alone (see IMPORTANT note at the top).
sed -i 's#"./data/unifi-protect.crt"#"/etc/ssl/private/unifi-core.crt"#' $PROTECT_CONFIG
sed -i 's#"./data/unifi-protect.key"#"/etc/ssl/private/unifi-core.key"#' $PROTECT_CONFIG

# Restart
info "Restarting services..."
systemctl restart unifi-core || error "Error trying to restart unifi-core"
systemctl restart nginx || error "Error trying to restart nginx"  # nginx terminates TLS since unifi-core 4.0
systemctl restart unifi-protect || error "Error trying to restart unifi-protect"

info "Completed."
