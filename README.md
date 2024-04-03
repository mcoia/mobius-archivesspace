# About

This repository is meant to make it easier to host multiple Archivesspace instances on a single server. It uses
docker-compose to facilitate the containers and networking between the proxy server and each instance. The proxy
server runs inside of a container. Each hosted instance of Archivesspace is also each in their own container.

This makes it easier to clone/upgrade/copy servers. It also makes it trivial to backup the server.

## Getting started

### Assumptions

This has only been tested on ubuntu server. Some of this code assumes things like "apt-get".

### Mysql setup

You need to have a MYSQL user setup for the control software. This MYSQL user needs to have the permission to:

Create users
Create databases
Grant privileges to users for newly created databases

Example mysql/mariadb setup
```
DROP USER IF EXISTS asadmin@'192.168.%.%';
CREATE USER asadmin@`192.168.%.%` IDENTIFIED BY 'password';
GRANT ALL ON *.* TO asadmin@`192.168.%.%` WITH GRANT OPTION;
GRANT GRANT OPTION ON `as\_%`.* TO asadmin@`192.168.%.%`;
FLUSH PRIVILEGES;
```

### Initialize your environment

```
git clone https://github.com/mcoia/mobius-archivesspace.git
cd mobius-archivesspace
sudo apt-get install ansible -y
cp vars.yml.example vars.yml
cp crontab_root.example crontab_root
cp backup_proxy_setup.sh.example backup_proxy_setup.sh
cp docker/as/app/vars.yml.example docker/as/app/vars.yml

# Setup your email address for letsencrypt ssl certificates
vi docker/as/proxy/pre/make_certs.sh
# Change nothing@nothing.com to your administrator email address

```

Edit **vars.yml** to meet your needs. Sendmail (**docker/as/app/vars.yml**) changes are required if you plan on having archivesspace email.

Correct the paths for **crontab_root** and **backup_proxy_setup.sh**

Execute:

`ansible-playbook -v setup_playbook.yml`

## Your first instance

After you've setup your server with the ansible script. You should be good to go.

```
# as root
./aspace_ctl.pl --action create --url new_aspace.domain.com
```

It assumes **latest** version of archivesspace.

If you want to specify a version:

```
# as root
./aspace_ctl.pl --action create --url new_aspace.domain.com --as_version v3.3.1
```

If you specify a version that is not available, the software will tell you and list all of the available versions.

If you just want to know the available versions:
```
# as root
./aspace_ctl.pl  --action create --url new_aspace.domain.com --as_version v1111
```

## Using aspace_ctl.pl

list details of a server
```
# as root
./aspace_ctl.pl --action list --url new_aspace.domain.com
```

list all

```
# as root
./aspace_ctl.pl --action list --all
```

You can also force the output to list downwards:

```
# as root
./aspace_ctl.pl --action listdown --all
```


### Adding / subtracting more

#### Adding more

```
# as root
./aspace_ctl.pl --action create --url new_aspace.domain.com --as_version v2.7.0
```

#### Removing a single

```
# as root
./aspace_ctl.pl --action delete --url new_aspace.domain.com
```

#### Removing without taking the time to backup

==Be careful, this will delete the instance without backing it up==

```
# as root
./aspace_ctl.pl --action delete --url new_aspace.domain.com --skip_backup
```

#### Removing all

```
# as root
./aspace_ctl.pl --action delete --all
```

### Backing up

### Single

```
# as root
./aspace_ctl.pl --action backup --url new_aspace.domain.com
```

### Backup all (cron)

```
# as root
./aspace_ctl.pl --action backup --all
```

==The default backup folder is a relative path ../backups==


## Creating from backup

You can create a new instance and restore it from a previous backup

```
# as root
./aspace_ctl.pl --action create --url new_aspace.domain.com --restore
```

==This assumes that you want the "last" backup.==

### If you want to supply a backup file

```
# as root
./aspace_ctl.pl --action create --url new_aspace.domain.com --restore --restore_from ../backups/new_aspace_domain_com/new_aspace_domain_com_XXXXXX.tar.gz
```

## CLoning

### You can clone a server to another for testing or other reason

```
./aspace_ctl.pl --action clone --url new_cloned_aspace.domain.com
```

## Upgrading

It's always a good idea to test an upgrade before upgrading for real.

### Upgrade Testing

This will create a new instance from* the specified instance, to the specified version of Archivesspace

```
./aspace_ctl.pl --action upgradetest --url current_aspace.domain.com --as_version v3.4.0
```
### In place Upgrade

You should run an upgradetest first

```
./aspace_ctl.pl --action upgrade --url current_aspace.domain.com --as_version v3.4.0
```





