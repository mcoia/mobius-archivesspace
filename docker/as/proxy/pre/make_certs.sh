#!/bin/bash

ACME="/root/.acme.sh/acme.sh"
ACMESHARED="/var/www/html"
#ACMELINK="/var/www/html/.well-known"
CERTS="/mnt/moss/apps/certs/acme"
NGINXCONF="/etc/nginx"
DEFAULTCA="--set-default-ca --server letsencrypt"
EMAIL_ADDRESS="nothing@nothing.com"


pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

GETCERTHOME () {
    # newest folder containing '.' in name.
    command export CERTHOME=$(find ${CERTS} -maxdepth 2 -type d -name "*.*" -printf '%T+ %p\n' | sort | tail -1 | awk '{print $2}') > /dev/null
}

####################################################
### -- installation
###
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [ ! -d "${CERTS}" ]; then
  mkdir -p ${CERTS}
  chown -R www-data.www-data ${CERTS}
  chmod -R a+rwX ${CERTS}
fi

pushd $PWD
if [ ! -f "${ACME}" ]; then
  apt-get install socat
  cd ~
  git clone https://github.com/Neilpang/acme.sh.git && cd acme.sh
  ./acme.sh --install --cert-home ${CERTS} --accountemail $EMAIL_ADDRESS

  export MAIL_FROM=$EMAIL_ADDRESS
  export MAIL_TO=$EMAIL_ADDRESS
  export MAIL_BIN="sendmail"
  $ACME --set-notify  --notify-hook mail --notify-level 2 --notify-mode 0
fi
$ACME --upgrade

####################################################
####  -- make ACEME protocol shared folder and link - must be visible from load balancer
####
if [ ! -d "${ACMESHARED}/.well-known" ]; then
  mkdir -p ${ACMESHARED}/.well-known
  chown -R www-data.www-data $ACMESHARED
  chmod -R 777 $ACMESHARED
fi
#if [ ! -L "${ACMELINK}" ]; then
#  sudo -u www-data ln -s ${ACMESHARED}/.well-known $ACMELINK
#fi


####################################################
####  -- make cert
####
#VHOSTS=$(/usr/sbin/apache2ctl -t -D DUMP_VHOSTS | grep "443 name" | grep -v localhost | awk '{print $4}' | xargs -i echo "-d " {} | paste -sd' ')
#VHOSTS=$(/usr/sbin/nginx -T | grep "server_name "  | grep -v ^\#  | awk '{print $2}' | sed 's/;//g' | sort | uniq | xargs -i echo "-d" {} | paste -sd' ') 2>/dev/null
VHOSTS=$(/usr/sbin/nginx -T | grep "server_name " | grep -v ^\#  | sed 's/;//g' | tr " " "\n" | grep -v server_name | sort | uniq | grep -v -e '^$' | xargs -i echo "-d" {} | paste -sd' ') 2>/dev/null
GETCERTHOME
if [[ -z "${CERTHOME}" ]]
then
  echo "Multi-domain CERTHOME not found so issue new cert."
  $ACME ${DEFAULTCA} --issue --cert-home ${CERTS} ${VHOSTS} -w ${ACMESHARED}
  #$ACME --debug 2 --issue --cert-home ${CERTS} ${VHOSTS} -w ${ACMESHARED}

else
### -- update cert
  CERT=$(find ${CERTHOME} -name "*.csr")
  #NEWVHOSTS=$(find /mnt/evergreen/apps/apacheconf -name "*.conf" -newer ${CERT})
  NEWVHOSTS=$(find ${NGINXCONF}/conf.d -name "*.conf" -newer ${CERT})
  if [[ ! -z "${NEWVHOSTS}" ]]
  then
    echo "Found updated conf on bind-mount ${NGINXCONF}/conf.d/ so update multi-domain cert to be safe."
    if [ ! -z "$1" ] && [ "$1" == '--force' ]
    then 
       echo "forcing cert renewal"
       $ACME ${DEFAULTCA} --force --debug 2 --issue --cert-home ${CERTS} ${VHOSTS} -w ${ACMESHARED}
    else
       $ACME ${DEFAULTCA} --debug 2 --issue --cert-home ${CERTS} ${VHOSTS} -w ${ACMESHARED}
    fi
  else
    echo "Running daily cert renewal check and update."
    $ACME ${DEFAULTCA} --cron --cert-home ${CERTS} --home "/root/.acme.sh"
  fi
fi


####################################################
#### -- refresh Apache/Nginx files on bind-mount /etc/nginx/conf.d
####
GETCERTHOME
cd $CERTHOME
echo CERTHOME: $CERTHOME

[ ! -f "${CERTS}/../latest/server.crt" ] && touch -d "2000-01-01 00:00:00" ${CERTS}/../latest/server.crt

NEWCERT=$(find . -name "*.cer" -newer ${CERTS}/../latest/server.crt)
if [[ ! -z "${NEWCERT}" ]]
then
  echo "Found updated CERT so refresh Apache/Nginx."
  cp fullchain.cer ${CERTS}/../latest/server.crt
  cp fullchain.cer ${CERTS}/../latest/nginx.crt
  find . -name "*.key" -exec cp {} ${CERTS}/../latest/server.key \;
fi

chown -R www-data.www-data ${CERTS}/..
chmod -R a+rwX ${CERTS}/..


####################################################
#### -- Install new crontab.
####
/usr/bin/crontab ${NGINXCONF}/pre/crontab_root

popd

