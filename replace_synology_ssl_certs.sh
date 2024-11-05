#!/bin/bash
#
# *** For DSM v7.x ***
#
# How to use this script:
#  1. Get your 3 PEM files ready to copy over from your local machine/update server (privkey.pem, fullchain.pem, cert.pem)
#     and put into a directory (this will be $CERT_DIRECTORY).
#     Personally, I use this script (https://gist.github.com/catchdave/3f6f412bbf0f0cec32469fb0c9747295) to automate steps 1 & 4.
#  2. Ensure you have a user setup on synology that has ssh access (and ssh access is setup).
#     This user will need to be able to sudo as root (i.e. add this line to sudoers, <USER> is the user you create):
#       <USER> ALL=(ALL) NOPASSWD: /var/services/homes/<USER>/replace_certs.sh
#  3. Copy this script to Synology: sudo scp replace_synology_ssl_certs.sh $USER@$SYNOLOGY_SERVER:~/
#  4. Call this script as follows:
#     sudo bash -c scp ${CERT_DIRECTORY}/{privkey,fullchain,cert}.pem $USER@$SYNOLOGY_SERVER:/tmp/ \
#     && ssh $USER@$SYNOLOGY_SERVER 'sudo ./replace_synology_ssl_certs.sh'

# Script start.

DEBUG=  # Set to any non-empty value to turn on debug mode
error_exit() { echo "[ERROR] $1"; exit 1; }
warn() { echo "[WARN ] $1"; }
info() { echo "[INFO ] $1"; }
debug() { [[ "${DEBUG}" ]] && echo "[DEBUG ] $1"; }

# 1. Initialization
# =================
[[ "$EUID" -ne 0 ]] && error_exit "Please run as root"  # Script only works as root

certs_src_dir="/usr/syno/etc/certificate/system/default"
services_to_restart=("nmbd" "avahi" "ldap-server")
packages_to_restart=("ScsiTarget" "SynologyDrive" "WebDAVServer" "ActiveBackup")
target_cert_dirs=(
    "/usr/syno/etc/certificate/system/FQDN"
    "/usr/local/etc/certificate/ScsiTarget/pkg-scsi-plugin-server/"
    "/usr/local/etc/certificate/SynologyDrive/SynologyDrive/"
    "/usr/local/etc/certificate/WebDAVServer/webdav/"
    "/usr/local/etc/certificate/ActiveBackup/ActiveBackup/"
    "/usr/syno/etc/certificate/smbftpd/ftpd/")

# Add the default directory
default_dir_name=$(</usr/syno/etc/certificate/_archive/DEFAULT)
if [[ -n "$default_dir_name" ]]; then
    target_cert_dirs+=("/usr/syno/etc/certificate/_archive/${default_dir_name}")
    debug "Default cert directory found: '/usr/syno/etc/certificate/_archive/${default_dir_name}'"
else
    warn "No default directory found. Probably unusual? Check: 'cat /usr/syno/etc/certificate/_archive/DEFAULT'"
fi

# Add reverse proxy app directories
for proxy in /usr/syno/etc/certificate/ReverseProxy/*/; do
    debug "Found proxy dir: ${proxy}"
    target_cert_dirs+=("${proxy}")
done

[[ "${DEBUG}" ]] && set -x

# 2. Move and chown certificates from /tmp to default directory
# =============================================================
mv /tmp/{privkey,fullchain,cert}.pem "${certs_src_dir}/" || error_exit "Halting because of error moving files"
chown root:root "${certs_src_dir}/"{privkey,fullchain,cert}.pem || error_exit "Halting because of error chowning files"
info "Certs moved from /tmp & chowned."

# 3. Copy certificates to target directories if they exist
# ========================================================
for target_dir in "${target_cert_dirs[@]}"; do
    if [[ ! -d "$target_dir" ]]; then
      debug "Target cert directory '$target_dir' not found, skipping..."
      continue
    fi

    info "Copying certificates to '$target_dir'"
    if ! (cp "${certs_src_dir}/"{privkey,fullchain,cert}.pem "$target_dir/" && \
        chown root:root "$target_dir/"{privkey,fullchain,cert}.pem); then
          warn "Error copying or chowning certs to ${target_dir}"
    fi
done

# 4. Restart services & packages
# ==============================
info "Rebooting all the things..."
for service in "${services_to_restart[@]}"; do
    /usr/syno/bin/synosystemctl restart "$service"
done
for package in "${packages_to_restart[@]}"; do  # Restart packages that are installed & turned on
    /usr/syno/bin/synopkg is_onoff "$package" 1>/dev/null && /usr/syno/bin/synopkg restart "$package"
done

# Restart nginx
if ! /usr/syno/bin/synow3tool --gen-all && sudo /usr/syno/bin/synosystemctl restart nginx; then
    warn "nginx failed to restart"
fi

info "Completed"
