#!/bin/bash

NGINXSSL="/etc/nginx/ssl"
CERTS="/mnt/moss/apps/certs/latest"

cd $NGINXSSL
[ ! -f "server.crt" ] && touch -d "2000-01-01 00:00:00" server.crt

cd $CERTS
NEWCERT=$(find . -name "server.crt" -newer ${NGINXSSL}/server.crt)
if [[ ! -z "${NEWCERT}" ]]
then
  echo "Found updated CERT so refresh Apache/Nginx."
  cp {server,nginx}.crt $NGINXSSL
  cp server.key $NGINXSSL
  #/usr/sbin/service apache2 restart
  /usr/sbin/nginx -s reload
fi
