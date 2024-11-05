#!/bin/bash
# This file renews SSL certificates on a "Unifi Protect Cloud Key+ Gen 2" that have already been copied over
# from my "create_ssl_certs.sh" script.
#
# Caveat: You will need to run this again if you upgrade software. I have noticed changes to 
#         file structures when Unifi updates minor versions, so no guarantee this will work above
#         OS 3.1.x.
# Prep: Add sudo perms to run this script for the user that executes this script, via visudo:
#       your_user_name ALL=NOPASSWD:/root/replace_certs_protect.sh

# Constants
TARGET=/etc/ssl/private
CORE_CONFIG=/usr/share/unifi-core/app/config/default.yaml  # Pre-3.1, this was config.yaml
PROTECT_CONFIG=/usr/share/unifi-protect/app/config/config.json
BACKUP_DIR=/root/ssl_backups
DATE=$(date '+%Y-%m-%d')

# Functions
# ============================
info() { echo "$0: [INFO] $1"; }
error() { echo "$0: [ERROR] $1"; }
error_exit() { echo "$0: [ERROR] $1"; exit 1; }
backup_config() {
    backup_file="$BACKUP_DIR/$(basename $1).$DATE"
    if [ ! -f "$backup_file" ]; then
        cp "$1" "$backup_file" || error_exit "Could not backup $1"
    else
        echo "$0: [WARN] Not saving copy of '$1' since a file already exists: $backup_file"
    fi
}
# ============================

# Verify root
if [ "$EUID" -ne 0 ]; then
  error_exit "$0: [ERROR] This script needs to run as root"
fi

# Verify new certificates were copied over before running.
if [[ ! -f /tmp/fullchain.pem || ! -f /tmp/privkey.pem ]]; then
    error_exit "No certificate files found in /tmp. Aborting."
fi

# Backup
info "Backing up old certs and config"
mkdir -p "$BACKUP_DIR"
backup_config "$TARGET/unifi-core.crt"
backup_config "$TARGET/unifi-core.key"
backup_config $CORE_CONFIG
backup_config $PROTECT_CONFIG

# Update
info "Replacing certificates"
mv /tmp/fullchain.pem "$TARGET/unifi-core.crt" || error_exit "Error replacing fullchain/unifi-core.crt"
mv /tmp/privkey.pem "$TARGET/unifi-core.key" || error_exit "Error replacing privkey/unifi-core.key"
chown root:root "$TARGET/unifi-core.crt" "$TARGET/unifi-core.key"
chmod o+r "$TARGET/unifi-core.crt" "$TARGET/unifi-core.key"  # unifi-protect user needs to access 

# Modifying config to point to new certs
sed -i "s#crt: '/data/unifi-core/config/unifi-core.crt'#crt: '/etc/ssl/private/unifi-core.crt'#" $CORE_CONFIG
sed -i "s#key: '/data/unifi-core/config/unifi-core.key'#key: '/etc/ssl/private/unifi-core.key'#" $CORE_CONFIG
sed -i 's#"./data/unifi-protect.crt"#"/etc/ssl/private/unifi-core.crt"#' $PROTECT_CONFIG
sed -i 's#"./data/unifi-protect.key"#"/etc/ssl/private/unifi-core.key"#' $PROTECT_CONFIG
sed -i 's#"./data/devices.crt"#"/etc/ssl/private/unifi-core.crt"#' $PROTECT_CONFIG
sed -i 's#"./data/devices.key"#"/etc/ssl/private/unifi-core.key"#' $PROTECT_CONFIG

# Restart
info "Restarting services..."
systemctl restart unifi-core || error "Error trying to restart unifi-core"
systemctl restart unifi-protect || error "Error trying to restart unifi-protect"

info "Completed."
