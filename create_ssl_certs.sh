# This is a anonymized version of the script I use to renew all my SSL certs
# across my servers. This will not work out of the box for anyone as your network will be
# different. But may be useful starting place for others.
#
# I use a cronjob that runs this every week. It only replaces certificates when a certificate has been renewed.

# Renews/creates cert from letsencrypt & places it where it needs to be.
# Currently, that is:
#    * DSM/Synology 
#    * Unifi Protect
#    * Home Assistant

DOMAIN=example.com  # Change to your domain
CERT_DIRECTORY="/etc/letsencrypt/live/$DOMAIN"
ME=$(basename "$0")
ONLY=
FORCE=false
CREATE_NEW_CERT=false
SERVERS=(synology homeassistant protect)  # Whatever your server names are
ssl_user=ssl_updater  # User for remote servers that can update certs

# Get args
# ================================
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -o|--only)
      if [[ ! " ${SERVERS[*]} " =~ " ${2} " ]]; then
        echo "[$ME] Unknown servername: $2. Use one of the known servers: $SERVERS"
        exit 1
      fi
      ONLY="$2"
      shift # past argument
      shift # past value
      ;;
    --force)
      FORCE=true
      shift # past argument
      ;;
    --create)
      CREATE_NEW_CERT=true
      shift # past argument
      ;;
    -*|--*)
      echo "[$ME] Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
# ================================

# Use certbot to renew certificate
# ================================
echo "Running certbot..."
if [ "$CREATE_NEW_CERT" == "true" ]; then
    echo "[$ME] Creating a new certificate from scratch"
    cert_flags="--insert-your-flags --creds etc *.$DOMAIN"  # Modify this line for the parameters you use to create your cert
    { CERTBOT_ERROR=$(sudo certbot certonly $cert_flags 2>&1 >&3 3>&-); } 3>&1
     errcode=$?
else
    echo "[$ME] Renewing certificate"
    { CERTBOT_ERROR=$(sudo certbot renew 2>&1 >&3 3>&-); } 3>&1
    errcode=$?
fi
if [ "$errcode" != "0" ]; then
    echo "$CERTBOT_ERROR"
    echo "[$ME] Error encountered with certbot. Halting."
    echo "[$ME] Error code: $errcode"
    exit
fi
# ================================

# Exit or continue if certificate not renewed, depending on flags
# ================================
if echo "$CERTBOT_ERROR" | grep 'Cert not yet due for renewal'; then
    if [ "$FORCE" != "true" ]; then
        echo "[$ME] Certbot not due for renewal--halting."
        echo "[$ME] To continue anyway (to sync the existing cert), use flag --force"
        exit 0
    else
        echo "[$ME] --force specified--continuing to sync certs"
    fi
fi

if [ "$ONLY" != "" ]; then
    echo "--only specified. Will only sync certs to: $ONLY"
fi
# ================================

# Synology (NAS)
# This script used here is referenced in this companion gist:
# https://gist.github.com/catchdave/69854624a21ac75194706ec20ca61327
# ================================
if [[ -z "$ONLY" || "$ONLY" == "synology" ]]; then
    server=synology.$DOMAIN
    echo ""
    echo "[$ME] Copying certificates to synology"
    sudo scp ${CERT_DIRECTORY}/{privkey,fullchain,cert}.pem $ssl_user@$server:/tmp/
    if [ "$?" = "0" ]; then
        echo "[$ME] > Replacing certs on $server...."
        ssh $ssl_user@$server 'sudo ./replace_certs.sh'
        if [ "$?" != "0" ]; then
            echo "[$ME] > ERROR replacing certs to $server"
        fi
    else
        echo "[$ME] > Error occurred copying files to $server"
    fi
fi
# ================================

# Home Assistant
# ================================
if [[ -z "$ONLY" || "$ONLY" == "homeassistant" ]]; then
    server=homeassistant.$DOMAIN
    echo ""
    echo "[$ME] Copying certificates to home assistant"
    sudo scp ${CERT_DIRECTORY}/{privkey,fullchain,cert}.pem $ssl_user@$server:/usr/share/hassio/ssl/
    if [ "$?" = "0" ]; then
        echo "[$ME] > Restarting NGINX SSL Proxy...."
        ssh $ssl_user@$server 'sudo ha addons restart core_nginx_proxy'
    else
        echo "[$ME] > Error occurred copying files to $server"
    fi
fi
# ================================

# Unifi Protect
# ================================
if [[ -z "$ONLY" || "$ONLY" == "protect" ]]; then
    server="protect.$DOMAIN"
    echo ""
    echo "[$ME] Copying certificates to $server"
    sudo scp ${CERT_DIRECTORY}/{privkey,fullchain}.pem $ssl_user@$server:/tmp/
    if [ "$?" = "0" ]; then
        echo "[$ME] > Restarting services on Unifi Protect...."
        ssh $ssl_user@$server 'sudo /root/replace_certs_protect.sh'
        if [ "$?" != "0" ]; then
            echo "[$ME] > ERROR restarting services on Unifi protect"
        fi
    else
        echo "[$ME] > Error occurred copying files to Unifi Protect"
    fi
fi
# ================================
