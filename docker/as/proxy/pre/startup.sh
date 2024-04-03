#/bin/bash 

# left as an example - gets dynamically created from aspace_ctl.pl
# export STAFFSKEL=asstaff.mobiusconsortium.org
# export PUBLICSKEL=aspublic.mobiusconsortium.org
# export DOCKERSKEL=app1
# envsubst \$STAFFSKEL,\$PUBLICSKEL,\$DOCKERSKEL < /etc/nginx/pre/site.template  > /etc/nginx/conf.d/site1.conf

/etc/init.d/nginx stop && rm -f /var/log/nginx/error.log && rm -f /var/log/nginx/access.log && touch /var/log/nginx/{access,error}.log
cp /etc/nginx/pre/nginx.conf /etc/nginx.conf
mkdir -p /var/www/html && chown -R www-data:www-data /var/www
mkdir -p /etc/nginx/ssl

cd /etc/nginx/ssl && openssl req -new -x509 -days 365 -nodes -out server.crt -keyout server.key -subj "/C=US/ST=MO/L=none/O=Company/OU=IT Department/CN=domain.com"
cp server.crt nginx.crt
openssl dhparam -out dhparam.pem 2048

/etc/init.d/nginx start

pgrep -fc startup.sh && exit
mkdir /etc/nginx/sites-available
mkdir /etc/nginx/sites-enabled
apt-get update
apt-get install -y procps psmisc net-tools vim less git cron mailutils
/etc/init.d/cron start
#cd /etc/nginx/pre/ && chmod 755 make_certs.sh && ./make_certs.sh
sleep infinity

