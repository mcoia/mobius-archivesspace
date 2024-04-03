#!/usr/bin/perl
# ---------------------------------------------------------------
# Copyright © 2020 MOBIUS
# Blake Graham-Henderson <blake@mobiusconsortium.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# ---------------------------------------------------------------

use lib qw(./);

$SIG{INT} = \&cleanup;
use Getopt::Long;
use Cwd;
use File::Path;
use DBhandler;
use Data::Dumper;
use JSON;
use Net::Address::IP::Local;
use Archive::Tar;
use IO::Zlib;

our $url_id;
our $staff_url;
our $log = "log_aspace_ctl.log";
# This setting applies to the db name AND the mysql username created.
# 32 characters seems to be the limit for the db username
# Mariadb is 60
# https://mariadb.com/kb/en/create-user/
# Mysql is 32
# https://dev.mysql.com/doc/refman/5.7/en/user-names.html
our $max_database_name_length = 32;
our $all = 0;
our $debug = 0;
our $drop_master_db = 0;
our $action;  # create, delete, deleteentry, upgrade, upgradtest, list, listdown, backup
our $as_version = "latest";
our $backup_retention_count = 3; # Keep 3 backup files
our $master_database = "as_master";
our $app_db_prefix = "as_";
our $skip_backup = 0;
our $local_my_cnf = $ENV{"HOME"} . "/.my.cnf";
our $restore = 0;
our $restore_from;
our $email_enabled;
our %foldersOnDisk = (); # used to track a directory listing over time
our %mysql_stuff = (
    host => "10.128.0.5",
    port => "3306",
    user => "asadmin",
    password => "password"
);
our %aspace_java_version_compatibility = (
    'v1.0' => "openjdk-8-jre", # covers all versions of archivesspace starting at this version and higher
    'v3.2' => "openjdk-11-jre"
);
our %aspace_solr_version_compatibility = (
    'v3.2' => "8.11.3" # covers all versions of archivesspace starting at this version and higher
);
our %solr_download_url = (
    '8.11.3' => "https://dlcdn.apache.org/lucene/solr/8.11.3/solr-8.11.3.tgz"
);
our $dbHandlerMaster;
our %app;
# Column name => print width
our %master_db_column_def =
(
'url' => 32,
'staff_url' => 32,
'db' => 15,
'db_usr' => 15,
'db_pass' => 13,
'as_version' => 7,
'local_username' => 15,
'local_shared_folder' => 25,
'last_backup' => 10,
'backup_folder' => 15
);

our @master_db_columns;
our $archives_space_release_url = "https://api.github.com/repos/archivesspace/archivesspace/releases";
our $archives_space_release_download_url = "https://github.com/archivesspace/archivesspace/releases/download/";
our %env;
our $cwd = getcwd;
our $docker_root = $cwd . "/docker/as";
our $env_file = "$docker_root/.env";
our $docker_compose_file = "$docker_root/docker-compose.yml";
our $proxy_site_template_file = "$docker_root/proxy/pre/site.template";
our $proxy_config_folder = "$docker_root/proxy/conf.d/";
our $brick_build_folder = "$docker_root/app/";
our $local_ip = Net::Address::IP::Local->public;

GetOptions (
"log=s" => \$log,
"debug" => \$debug,
"action=s" => \$action,
"url=s" => \$url_id,
"app_db_prefix=s" => \$app_db_prefix,
"master_database=s" => \$master_database,
"as_version=s" => \$as_version,
"staff_url=s" => \$staff_url,
"local_my_cnf=s" => \$local_my_cnf,
"drop_master_db" => \$drop_master_db,
"all" => \$all,
"restore" => \$restore,
"restore_from=s" => \$restore_from,
"skip_backup" => \$skip_backup,
"email_enabled" => \$email_enabled,
)
or die("Error in command line arguments\nYou can specify
--log path_to_log_output.log                  [Path to the log output file - required]

\n");

sub help
{
    print <<HELP;
$0
--action                  [Required: What this program should do: create, delete(entry), backup, list, listdown, clone]
--url                     [Required: This is the how we identify a customer: AKA archive.customer.com]
--staff_url               [Not Required: This is the staff URL setting. Defaults to staff.[url]]
--as_version              [Not Required: Defaults to "latest" only used for "create" action]
--all                     [Not Required: Forces context for ALL customers, not just the one specified in url]
--restore                 [Not Required: Used during action: create. Defaults to last backup file. Both folder and DB restoration]
--restore_from            [Not Required: Used when restoring. Path to file. Override the backup file to the specified here, can be tar.gz or .sql file]
--app_db_prefix           [Not Required: Override the default Database creation prefix. Defaults to 'as_']
--master_database         [Not Required: Override the default master database name. Defaults to 'as_master']
--local_my_cnf            [Not Required: Path to .my.cnf file where mysql creds are store (for master account). Default ~/.my.cnf]
--debug                   [Not Required: switch on more verbosity on STDOUT and log]
--drop_master_db          [Not Required: Forces the program to re-create the master database. Usually used when changing the recorded master db columns]
--skip_backup             [Not Required: When deleting, this will skip the backup routine prior to deletion]
--log                     [Not Required: A log file for this program to dump it's log. Defaults to working dir/log_aspace_ctl.log]

Note:
"delete" will perform a backup (Unless you pass "skip_backup") and then remove the container and everything
"deleteentry" will do everything from "delete" and then also remove the entry from the master database. You can do these in two steps if you want.

"upgrade" will take the running container down and replace it with a new one, stock archivesspace plus the database restored
"upgradetest" will make a copy of the running container's database and restore it into a new database. You will be prompted to supply the new container details.

"clone" is similar to upgradetest, but in this case, it will create a new container with new URL's but restore the file system as well as the db. You will be prompted to supply the new container details.

HELP
    exit;
}


# go ahead and lowercase the input globally
$url_id = lc $url_id;
$as_version = lc $as_version;
$action = lc $action;

# Make sure the user supplied ALL of the options
help() if(!$log);
help() if(!$action);
help() if( ($action ne 'create') && ($action ne 'clone') && !($action =~ m/delete/) && ($action ne 'backup') && !($action =~ m/list/) && !($action =~ m/upgrade/) );
help() if(!$url_id && $action =~ m/list/ && !$all);
help() if(!$url_id && $action =~ m/upgrade/);

$log = new Loghandler($log);
$log->truncFile('');

# Fill column array from definition, keeps them in the same order
while ((my $key, my $val) = each(%master_db_column_def))
{
    push @master_db_columns, $key;
}

createMasterDatabase();

# Consume all those juicy variables
%env = %{readConfig($env_file)};

# see what's running now and make sure the DB understands "active" for each of them
syncRunningContainersToDB();

if( $action eq 'create' )
{
    ## check storage to see if we've already created all the stuff for this URL
    readStorage($url_id);
    print "This URL already exists '$url_id'\n" if $app{'active'};
    exit if $app{'active'};

    # Makeup a new username, database, etc.
    generateNewVars($url_id) if !$app{'id'};

    ## Figure out if the specified version is real and can be downloaded
    dealWithASVersion();

    # Create the local username and home folder
    dealWithLocalUserAccount($action);
    restoreData('folder') if $restore;

    setupASTarAndSettings();

    # Create the database
    dealWithAppDatabase($action);
    restoreData('db') if $restore;

    ## Edit docker-compose.yml
    dealWithDockerCompose("delete");  ## clean any entries that might already exist
    dealWithDockerCompose($action);

    ## Setup proxy config files
    dealWithProxy($action);

    dealWithDockerService($action);

    $app{"active"} = 1;
    saveStorage();

    $log->addLine(Dumper(\%env)) if $debug;
    $log->addLine(Dumper(\%app)) if $debug;
    reportVars(1,1); #show header, list downwards
}
elsif ( $action =~ m/delete/ )
{
    readStorage($url_id);
    my @all = (\%app);
    if($all)
    {
        promptUser("\n\nDid you really want to delete ALL of the containers? You can stop now CTRL+C or forever hold your peace!");
        syncRunningContainersToDB();
        @all = @{getAllMasterDBEntries()} if ($all);
    }
    foreach(@all)
    {
        %app = %{$_};
        if($app{"local_username"} && length($app{"local_username"}) > 0)
        {
            execDockerCMD($app{"local_username"}, "sh -c '/home/archivesspace/archivesspace/archivesspace.sh stop'", 0, 1); # Stop Archivespace, ignore errors
            dealWithBackup() if !$skip_backup; # Backing up first
            dealWithDockerService($action);
            dealWithProxy($action);
            dealWithDockerCompose($action);
            dealWithAppDatabase($action);
            dealWithLocalUserAccount($action);
            my $answer = promptUser("Would you like me to delete '" . $app{"local_shared_folder"} ."'\nANSWER (y/n)");
            if( (-d $app{"local_shared_folder"}) &&  ($answer =~ m/^ye?s?$/i) )
            {
                setupASTarAndSettings('delete');
            }
            $app{"active"} = 0;
            saveStorage();
            if( $action =~ m/entry/ )
            {
                promptUser("The container/user/proxy/ has be removed, now, we're removing the master db entry");
                saveStorage(1);
            }
            reportVars(1, 1); #show header, list downwards
        }
        else
        {
            promptUser("Didn't find a brick by that name: '" . $app{"url"} . "'");
        }
    }
}
elsif ( $action eq 'backup' )
{
    readStorage($url_id);
    my @all = (\%app);
    @all = @{getAllMasterDBEntries(1)} if ($all);
    foreach(@all)
    {
        %app = %{$_};
        dealWithBackup();
    }
}
elsif ( $action =~ m/^list/ )
{
    readStorage($url_id);
    my @all = (\%app);
    @all = @{getAllMasterDBEntries()} if ($all);
    my $down = ($action =~ m/down/);
    my $first = 1;
    foreach(@all)
    {
        %app = %{$_};
        reportVars($first, $down);
        $first = 0;
    }
    print "\n";
}
elsif ( $action =~ m/^upgrade/ )
{
    readStorage($url_id);
    if(!$app{'id'})
    {
        promptUser("Sorry, '$url_id' doesn't exist.\nNothing to upgrade");
        exit;
    }
    my %holding = %app;
    promptUser("Did you forget to supply a version? Using 'latest'. CTRL+C now if you need") if($as_version eq 'latest');

    promptUser("
- 'upgradetest' -
The upgrade process handled by this software will
dump the latest SQL and restore that into another database. Once restored,
the destination version of Archive Space will be loaded into the container
and started. Archive Space will upgrade the database to match the verson.
This is all best-effort. Some manual intervention might be required.

- 'upgrade' -
If you chose 'upgrade' (not 'upgradetest') then the chosen URL will be recreated
with the new version of Archive Space. The new version will be stock. The database will
be restored onto the resulting container but the filesystem will be stock. Any
customizations will need to be re-introduced into the resulting container.
You can cancel now CTRL+C ");

    if( $action =~ m/test/ )
    {
        my $destURL = promptUser("You've elected for a TEST upgrade. Good for you.
Please enter the test URL");
        readStorage($destURL);

        print "This URL already exists '$destURL'\n" if $app{'active'};
        exit if $app{'active'};

        my $destStaffURL = promptUser("Please enter the test STAFF URL. Blank for default:\nstaff.$destURL");
        $app{"staff_url"} = $destStaffURL if($destStaffURL && length($destStaffURL) > 0);

        # Makeup a new username, database, etc.
        generateNewVars($destURL) if !$app{'id'};

        ## Figure out if the specified version is real and can be downloaded
        dealWithASVersion();

        my %back = %app;

        %app = %holding; # stage the original app back
        dealWithBackup('db');
        $restore_from = $app{"backup_folder"} . "/" . $app{"local_username"} . ".sql";
        if(!(-e $restore_from))
        {
            promptUser("Couldn't get a sql backup from existing db");
            exit;
        }
        %app = %back; # Put humpty dumpty back together

        # Create the local username and home folder
        dealWithLocalUserAccount('create');

        setupASTarAndSettings();

        # Create the database
        dealWithAppDatabase('create');
        restoreData('db');

        ## Edit docker-compose.yml
        dealWithDockerCompose("delete");  ## clean any entries that might already exist
        dealWithDockerCompose('create');

        ## Setup proxy config files
        dealWithProxy('create');

        dealWithDockerService('create');

        $app{"active"} = 1;
        saveStorage();

        $log->addLine(Dumper(\%env)) if $debug;
        $log->addLine(Dumper(\%app)) if $debug;
        reportVars(1,1); #show header, list downwards
    }
    else
    {
        execDockerCMD($app{"local_username"}, "sh -c '/home/archivesspace/archivesspace/archivesspace.sh stop'", 0, 1); # Stop Archivespace, ignore errors
        dealWithBackup('db');
        my $sql_file = $app{"backup_folder"} . "/" . $app{"local_username"} . ".sql";
        if(!(-e $sql_file))
        {
            promptUser("Couldn't get a sql backup from existing db");
            execDockerCMD($app{"local_username"}, "sh -c '/home/archivesspace/archivesspace/archivesspace.sh start'", 0); # return to good state
            exit;
        }
        $restore_from = $app{"backup_folder"} . "/upgrade_tmp_" . $app{"local_username"} . ".sql";
        execSystemCMD("cp '$sql_file' '$restore_from'");

        dealWithBackup('folder') if !$skip_backup;
        dealWithDockerService('delete');
        dealWithProxy('delete');
        dealWithDockerCompose('delete');
        dealWithAppDatabase('delete');
        setupASTarAndSettings('delete');
        $app{"active"} = 0;
        saveStorage();

        # Now, upgrade

        # Get user ID and group ID, I know they already exist but those variables are null here.
        dealWithLocalUserAccount('create');
        $app{"as_version"} = $as_version;
        ## Figure out if the specified version is real and can be downloaded
        dealWithASVersion();

        setupASTarAndSettings();

        # Create the database
        dealWithAppDatabase('create');
        restoreData('db');

        ## Edit docker-compose.yml
        dealWithDockerCompose('create');

        ## Setup proxy config files
        dealWithProxy('create');

        dealWithDockerService('create');

        $app{"active"} = 1;
        saveStorage();

        $log->addLine(Dumper(\%env)) if $debug;
        $log->addLine(Dumper(\%app)) if $debug;
        reportVars(1,1); #show header, list downwards
        print boxText("If it's not working, try running the DB script inside the container:\ncd /home/archivesspace/archivesspace/scripts && ./setup-database.sh");
        print boxText("If that doesn't work, you might need to manually put the mysql connector jar file inside the container (archivesspace/lib): 
        curl -LsO https://repo1.maven.org/maven2/mysql/mysql-connector-java/".$env{"MYSQLJ_VERSION"}."/mysql-connector-java-".$env{"MYSQLJ_VERSION"}.".jar");
    }

}
elsif ( $action eq 'clone' )
{
    readStorage($url_id);
    if(!$app{'id'})
    {
        promptUser("Sorry, '$url_id' doesn't exist.\nNothing to clone");
        exit;
    }
    my %holding = %app;
    $as_version = $app{'as_version'}; # cloning the same version

    my $destURL = promptUser("You've elected for a clone.
Please enter the URL for the clone");
    readStorage($destURL);

    print "This URL already exists '$destURL'\n" if $app{'active'};
    exit if $app{'active'};

    my $destStaffURL = promptUser("Please enter the test STAFF URL. Blank for default:\nstaff.$destURL");
    $app{"staff_url"} = $destStaffURL if($destStaffURL && length($destStaffURL) > 0);

    # Makeup a new username, database, etc.
    generateNewVars($destURL) if !$app{'id'};

    ## Figure out if the specified version is real and can be downloaded
    dealWithASVersion();

    my %back = %app;

    %app = %holding; # stage the original app back

    $restore_from = dealWithBackup();
    if(!(-e $restore_from))
    {
        promptUser("Couldn't backup original container");
        exit;
    }
    %app = %back; # Put humpty dumpty back together

    # Create the local username and home folder
    dealWithLocalUserAccount('create');
    restoreData('folder');

    setupASTarAndSettings();

    # Create the database
    dealWithAppDatabase('create');
    # Tricky business, need to temporarily put in the source username for the db restore so that the routine can find the proper sql file within the archive
    $app{'local_username'} = $holding{'local_username'};
    restoreData('db');
    $app{'local_username'} = $back{'local_username'};

    ## Edit docker-compose.yml
    dealWithDockerCompose("delete");  ## clean any entries that might already exist
    dealWithDockerCompose('create');

    ## Setup proxy config files
    dealWithProxy('create');

    dealWithDockerService('create');

    $app{"active"} = 1;
    saveStorage();

    $log->addLine(Dumper(\%env)) if $debug;
    $log->addLine(Dumper(\%app)) if $debug;
    reportVars(1,1); #show header, list downwards
}
else
{
    print "You need to specify a supported action:  create, delete, deleteentry, upgrade, upgradetest, clone, backup, list, listdown\n";
    exit;
}

sub getDockerID
{
    my $search = shift;
    my $include_non_running = shift;
    my $non_running_switch = '';
    $non_running_switch = "-a" if $include_non_running;
    my $cmd = "docker ps $non_running_switch -f name=\"$search\" --format \"{{.ID}}\"";
    my $id = execSystemCMDWithReturn($cmd);
    print "Container '$search' is '$id'\n";
    return $id;
}

sub reportVars
{
    my $show_header = shift;
    my $down = shift;
    my @order = ();
    while ((my $key, my $val) = each(%app))
    {
        push(@order, $key);
    }
    @order = sort @order;
    my $ret = "";
    my $header = "";
    my $downward = "== " . $app{'url'} . " ==\n";
    foreach(@order)
    {
        my $data = $app{$_};
        # Make booleans look nicer for humans
        $data = 'Yes' if ( ($data eq '1') && ($_ ne 'id') );
        $data = 'No' if ( ($data eq '0') && ($_ ne 'id') );
        my $width = $master_db_column_def{$_} || 10; # default 10 wide for some of those non-db vars
        $ret .= makeEvenWidth($data, $width) . ' ';
        $header .= makeEvenWidth($_, $width) . ' ';
        $downward .= makeEvenWidth($_.":", 50) . "'$data'\n";
    }
    $ret = "$header\n$ret" if $show_header;
    $ret = $downward . "\n" if $down;
    $ret = "\n$ret";
    print $ret;
}

sub dealWithBackup
{
    my $type = shift;

    my @types = ();
    push (@types, $type) if $type;
    @types = ('db','folder') if !$type;
    my $tar_file;

    foreach(@types)
    {
        $type = $_;
        mkdir $env{"BACKUP_FOLDER"} if(!(-d $env{"BACKUP_FOLDER"}));
        mkdir $app{"backup_folder"} if(!(-d $app{"backup_folder"}));
        my $dt = DateTime->now(time_zone => "local");
        my $fdate = $dt->ymd;
        my $ftime = $dt->hms;
        $ftime =~ s/://g;
        my $dateString = $fdate . "_" . $ftime;
        my $sql_file = $app{"backup_folder"} . "/" . $app{"local_username"} . ".sql";

        my $cmd = "mysqldump --routines --column-statistics=0 " . $app{"db"} . " > $sql_file";
        if($type eq 'db')
        {
            print boxText("Backing up DB...");
            execSystemCMD($cmd);
        }
        else
        {
            $cmd = "du -sh " . $app{"local_shared_folder"} . " | awk \"{print \\\$1}\"";
            my $amount = execSystemCMDWithReturn($cmd);
            $tar_file = $app{"backup_folder"} . "/" . $app{"local_username"} . "_$dateString.tar.gz";
            print boxText("Backing up files/folders:\n $amount worth of stuff, might be a minute");
            $cmd = "cd " . $app{"local_shared_folder"} . " && tar --exclude='archivesspace/logs' --exclude='archivesspace/data/solr_index' --exclude='archivesspace/data/indexer_state' --exclude='archivesspace/data/indexer_pui_state' --exclude='archivesspace/data/tmp' -czf $tar_file archivesspace || touch /tmp/backup_failure.lock";
            execSystemCMD($cmd);
            if( -e $sql_file)
            {
                $tar_file = $app{"backup_folder"} . "/" . $app{"local_username"} . "_$dateString.tar.gz";
                my $tar = Archive::Tar->new($tar_file);
                my $sql_backup_file = Archive::Tar::File->new(file => $sql_file);
                $sql_backup_file->rename($app{"local_username"} . ".sql");
                $tar->add_files($sql_backup_file);
                $tar->write($tar_file.".tmp", COMPRESS_GZIP);
                $cmd = "cd " . $app{"local_shared_folder"} . " && rm $tar_file && mv $tar_file".".tmp $tar_file && rm $sql_file";
                execSystemCMD($cmd);
                $app{"last_backup"} = $fdate. " $ftime";
                saveStorage();
            }
            rotateBackups();
        }
    }
    return $tar_file if $tar_file;
}

sub dealWithDockerService
{
    my $do = shift;
    if($do eq "create")
    {
        my $java_version = figureASCompatibleVersion(\%aspace_java_version_compatibility);
        startContainer($app{"local_username"}, 1);
        startContainer("proxy", 1);

        print "installing: $java_version\n";
        execDockerCMD($app{"local_username"}, "apt-get install -y $java_version", 1);

        execSystemCMD("cp $brick_build_folder"."/entrypoint.sh " . $app{"local_shared_folder"} . "/");
        execSystemCMD("cp $brick_build_folder"."/brick_create_init.yml " . $app{"local_shared_folder"} . "/");
        if($email_enabled)
        {
            promptUser("You've elected to enable email. Now's your chance to double check this file:\n$brick_build_folder"."/vars.yml");
            execSystemCMD("cp $brick_build_folder"."/sendmail.yml " . $app{"local_shared_folder"} . "/");
            execSystemCMD("cp $brick_build_folder"."/vars.yml " . $app{"local_shared_folder"} . "/");
        }

        execSystemCMD("rm $brick_build_folder"."/.my.cnf") if (-f "$brick_build_folder"."/.my.cnf");
        execSystemCMD("rm $brick_build_folder"."/mysql-configured") if (-f "$brick_build_folder"."/mysql-configured");
        execSystemCMD("rm -Rf $brick_build_folder"."/archivesspace") if (-d "$brick_build_folder"."/archivesspace");

        execDockerCMD($app{"local_username"}, "chmod 755 /home/archivesspace/entrypoint.sh", 1);
        execDockerCMD($app{"local_username"}, "usermod -u ". $app{"uid"} . " archivesspace", 1);
        execDockerCMD($app{"local_username"}, "groupmod -g ". $app{"gid"} . " archivesspace", 1);
        execDockerCMD($app{"local_username"}, "apt-get install -y ansible", 1);
        execDockerCMD($app{"local_username"}, "ansible-playbook brick_create_init.yml", 0);
        if($email_enabled)
        {
            promptUser("Remember: Archivesspace needs several configuration tweaks for email to work:\npui_email_raise_delivery_errors\npui_email_perform_deliveries\npui_email_sendmail_settings\npui_email_delivery_method\npui_email_enabled\npui_email_override\npui_request_email_fallback_to_address\npui_request_email_fallback_from_address");
            execDockerCMD($app{"local_username"}, "ansible-playbook sendmail.yml", 0);
        }

        # start solr if this version of archivesspace needs it
        # if this fails, it's ok, this script should keep going
        execDockerCMD($app{"local_username"}, "solr_app/bin/solr start", 0);
        # init solr's archivesspace core index
        execDockerCMD($app{"local_username"}, "solr_app/bin/solr create -c archivesspace -d archivesspace", 0);

        # best attempt to get the connector jar downloaded into the container. entrypoint.sh also does this, but this is a double effort
        # because it seems to fail sometimes. Gumming up the whole show
        execDockerCMD($app{"local_username"},
        "sh -c 'cd /home/archivesspace/archivesspace/lib && ".
        "curl -LsO https://repo1.maven.org/maven2/mysql/mysql-connector-java/".$env{"MYSQLJ_VERSION"}."/mysql-connector-java-".$env{"MYSQLJ_VERSION"}.".jar'");

        promptUser("We are all set. Entrypoint on container is next.");

        execDockerCMD($app{"local_username"}, "/bin/bash /home/archivesspace/entrypoint.sh");
    }
    elsif($do =~ m/delete/)
    {
        stopContainer($app{"local_username"});
    }
    else
    {
        $log->addLogLine("dealWithDockerService - You've asked me to do '$do' - not something I know how to do");
        exit;
    }
}

sub startContainer
{
    my $container_name = shift;
    my $do_build = shift;
    my $build_switch = '';
    $build_switch = "--build" if $do_build;

    my $container_id = getDockerID($container_name);
    my $cmd = "cd $docker_root && docker-compose up -d $build_switch $container_name";
    $cmd .= ' &' if($container_name eq 'proxy' && !$container_id );

    execSystemCMD( $cmd ) unless ( ($container_id && length($container_id) > 0));
    if($container_name eq 'proxy')
    {
        $container_id = getDockerID($container_name);
        my $tries = 0;
        while(!$container_id && $tries < 20)
        {
            sleep 1;
            $container_id = getDockerID($container_name);
            $tries++;
        }
        if(!$container_id)
        {
            print boxText("Couldn't get the proxy container started. Exiting");
            exit;
        }
        print boxText("Waiting for proxy container to come online") if $tries > 0;
        sleep 20 if $tries > 0; #it takes awhile for it to become ready for commands
    }

    $container_id = getDockerID($container_name);
    if(!$container_id)
    {
        print "Couldn't get '$container_name' started. You're going to have to fix this by hand\n";
        exit;
    }
    else
    {
        my $docker_id = getDockerID("proxy");
        # only when there is a proxy container
        # Handling the case when this container is the first and proxy hasn't got started yet
        execDockerCMD("proxy", "/bin/bash /etc/init.d/nginx reload", 1) if($docker_id);
    }
}

sub stopContainer
{
    my $container_name = shift;
    my $container_id = getDockerID($container_name, 1);
    if($container_id) # Make sure there is a container to stop
    {
        execSystemCMD( "cd $docker_root && docker-compose rm -fs $container_name", 1) if ( ($container_id && length($container_id) > 0));
        $container_id = getDockerID($container_name);
        if($container_id)
        {
            promptUser("Couldn't kill '$container_name'. You're going to have to fix this by hand");
        }
    }
    my $cmd = "docker ps --format \"{{.ID}}\"";
    my $ids = execSystemCMDWithReturn($cmd);
    print "These are the containers:\n$ids\n" if $debug;
    my @count = split("\n",$ids);
    my $num = $#count + 1;
    print boxText("$num containers left");
    if( $#count < 1) # If there is only one running (proxy server) - then kill the whole thing.
    {   
        print $num . " Containers running\n Shutting down everything.....\n";
        execSystemCMD("cd $docker_root && docker-compose down --rmi all --remove-orphans", 1);
    }
}

sub dealWithProxy
{
    my $do = shift;

    # left as an example - gets dynamically created from aspace_ctl.pl
    # export STAFFSKEL=asstaff.mobiusconsortium.org
    # export PUBLICSKEL=aspublic.mobiusconsortium.org
    # export DOCKERSKEL=app1
    # envsubst \$STAFFSKEL,\$PUBLICSKEL,\$DOCKERSKEL < /etc/nginx/pre/site.template  > /etc/nginx/conf.d/site1.conf


    if( -f $proxy_site_template_file )
    {

        ## Make sure the root certs folder exists
        mkdir $env{"ROOT_SHARED_FOLDER"} . "/certs" if ( !(-d $env{"ROOT_SHARED_FOLDER"} . "/certs"));
        my $proxy_output_file = "$proxy_config_folder" . $app{"local_username"} . ".conf";
        my %substitutions =
        (
            '\$\{STAFFSKEL\}' => $app{"staff_url"},
            '\$\{PUBLICSKEL\}' => $app{"url"},
            '\$\{DOCKERSKEL\}' => $app{"local_username"}
        );
        if($do eq 'create')
        {
            my $proxy_template_file = new Loghandler($proxy_site_template_file);
            my @template_lines = @{$proxy_template_file->readFile()};
            my $output = "";
            foreach(@template_lines)
            {
                my $this_line = $_;
                while ((my $key, my $val) = each(%substitutions))
                {
                    $this_line =~ s/$key/$val/g;
                }
                $output.= "$this_line";
            }
            print "opening $proxy_output_file\n";
            $log->addLine($output);
            my $proxy_output = new Loghandler($proxy_output_file);
            $proxy_output->truncFile($output);
        }
        elsif($do =~ m/delete/)
        {
            unlink $proxy_output_file;
        }
        else
        {
            $log->addLogLine("dealWithProxy - You've asked me to do '$do' - not something I know how to do");
            exit;
        }
    }
    else
    {
        $log->addLogLine("I can't find the site.template file. Trying to find it here: $proxy_site_template_file");
        print "I can't find the site.template file. Trying to find it here: $proxy_site_template_file\n";
        exit;
    }
}

sub dealWithDockerCompose
{
    my $do = shift;
### Example clause that we want to see in the docker-compose file
  # app containers.
  # app1:
    # <<: *baseapp
    # image: as_app1
    # hostname: app1.localdomain
    # # pass config.env file vars to this container.
    # env_file: ${ROOT_SHARED_FOLDER}/app1/config.env
    # volumes:
      # - ${ROOT_SHARED_FOLDER}/app1:${ASHOME}

    if( -f $docker_compose_file )
    {
        if($do eq 'create')
        {
            dockerComposeEditor("services","  " . $app{"local_username"} . ":",$do);
            dockerComposeEditor("services/" . $app{"local_username"}  ,'  volumes:', $do);
            dockerComposeEditor("services/" . $app{"local_username"} . "/volumes" ,'  - ' . $app{"local_shared_folder"} . ':${ASHOME}', $do);
            dockerComposeEditor("services/" . $app{"local_username"}  ,'  env_file: '. $app{"local_shared_folder"} . "/config.env", $do);
            dockerComposeEditor("services/" . $app{"local_username"}  ,'  hostname: '.  $app{"local_username"} . ".localdomain", $do);
            dockerComposeEditor("services/" . $app{"local_username"} ,'  <<: *baseapp',$do);

            dockerComposeEditor("services/proxy/depends_on", "  - " . $app{"local_username"}, $do);
            my $envFile = new Loghandler($app{"local_shared_folder"} . "/config.env");
            my $output = "MYSQL_DATABASE=" . $app{"db"} . "\n";
            $output .= "MYSQL_USER=" . $app{"db_usr"} . "\n";
            $output .= "MYSQL_PASSWORD=" . $app{"db_pass"} . "\n";
            $output .= "FRONTEND_PROXY_URL=https://" . $app{"staff_url"} . "\n";
            $output .= "PUBLIC_PROXY_URL=https://" . $app{"url"};
            $envFile->truncFile($output);
        }
        elsif($do =~ m/delete/)
        {
            dockerComposeEditor("services/proxy/depends_on/" . $app{"local_username"}, '', $do);
            my $v = $app{"local_shared_folder"};
            $v =~ s/\//!!!/g;
            dockerComposeEditor("services/" . $app{"local_username"} . "/volumes/$v",'', $do);
            dockerComposeEditor("services/" . $app{"local_username"} ."/volumes",'', $do);
            dockerComposeEditor("services/" . $app{"local_username"} ."/env_file", '', $do);
            dockerComposeEditor("services/" . $app{"local_username"} ."/hostname", '', $do);
            dockerComposeEditor("services/" . $app{"local_username"} ."/<<", '', $do);
            dockerComposeEditor("services/" . $app{"local_username"},'',$do);
            my $envFile = new Loghandler($app{"local_shared_folder"} . "/config.env");
            $envFile->deleteFile();
        }
        else
        {
            $log->addLogLine("dealWithDockerCompose - You've asked me to do '$do' - not something I know how to do");
            exit;
        }
    }
    else
    {
        $log->addLogLine("I can't find the docker-compose.yml file. Trying to find it here: $docker_compose_file");
        print "I can't find the docker-compose.yml file. Trying to find it here: $docker_compose_file\n";
        exit;
    }
}

sub dealWithLocalUserAccount
{
    my $do = shift;
    $log->addLine(Dumper(\%env));
    $log->addLine(Dumper(\%app));

    if( $app{"local_username"} && length($app{"local_username"}) > 0 && $env{"ROOT_SHARED_FOLDER"}  && length($env{"ROOT_SHARED_FOLDER"} ) > 0 )
    {
        mkdir $env{"ROOT_SHARED_FOLDER"} if ( !( -d $env{"ROOT_SHARED_FOLDER"}) );

        my $cmd = "cut -d: -f1 /etc/passwd";
        my $allUsers = execSystemCMDWithReturn($cmd);
        my $user = $app{"local_username"};

        if($do eq 'create')
        {
            $log->addLine("current system users:\n". $allUsers) if $debug;
            if( !($allUsers =~ m/$user/g) )
            {
                $cmd = "useradd -U -m -b " . $env{"ROOT_SHARED_FOLDER"} . " -s /bin/false " . $app{"local_username"};
                execSystemCMD($cmd);
            }
            $cmd = "id -u " . $app{"local_username"};
            $app{"uid"} = execSystemCMDWithReturn($cmd);
            $cmd = "id -g " . $app{"local_username"};
            $app{"gid"} = execSystemCMDWithReturn($cmd);
            $cmd = "eval echo \"~" . $app{"local_username"} . "\"";
            $app{"local_shared_folder"} = execSystemCMDWithReturn($cmd);
        }
        elsif($do =~ m/delete/)
        {
            if( ($allUsers =~ m/$user/g) )
            {
                my $cmd = "userdel -f -r " . $app{"local_username"};
                execSystemCMD($cmd);
            }
            $cmd = "cut -d: -f1 /etc/group";
            my $allGroups = execSystemCMDWithReturn($cmd);
            if( ($allGroups =~ m/$user/g) )
            {
                $cmd = "groupdel " . $app{"local_username"};
                execSystemCMD($cmd);
            }

            undef $app{"uid"};
            undef $app{"gid"};
        }
        else
        {
            $log->addLogLine("dealWithLocalUserAccount - You've asked me to do '$do' - not something I know how to do");
            exit;
        }
    }
    else
    {
        $log->addLogLine("I can't create a user with no name, niether can I create a user without a base folder. Check .env file for ROOT_SHARED_FOLDER");
        print "I can't create a user with no name\n";
        exit;
    }
}

sub dealWithAppDatabase
{
    my $do = shift;


    if ($do eq 'create')
    {
        my $query = "DROP USER IF EXISTS " . $app{"db_usr"} . "\@`%`";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        $query = "CREATE USER IF NOT EXISTS " . $app{"db_usr"} . "\@`%` IDENTIFIED WITH mysql_native_password BY '" . $app{"db_pass"} . "'";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        $query = "GRANT ALL PRIVILEGES ON " . $app{"db"} . ".* TO " . $app{"db_usr"} . "\@`%`";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        $query = "GRANT CREATE,UPDATE,SELECT,DROP,DELETE ON " . $app{"db"} . ".* TO " . $app{"db_usr"} . "\@`%`";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        $query = "FLUSH PRIVILEGES";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        my $dbSetupConnection = new DBhandler(0,$mysql_stuff{'host'},$app{"db_usr"},$app{"db_pass"},$mysql_stuff{'port'}||"3306","mysql");
        $query = "CREATE DATABASE IF NOT EXISTS " . $app{"db"} . " DEFAULT CHARACTER SET UTF8";
        $log->addLogLine($query) if $debug;
        $dbSetupConnection->update($query);
        $query = "FLUSH PRIVILEGES";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        $dbSetupConnection->breakdown();
        $dbSetupConnection = undef;
    }
    elsif ($do =~ m/delete/)
    {
        my $query = "DROP USER IF EXISTS " . $app{"db_usr"} . "\@'%'";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
        $query = "DROP DATABASE IF EXISTS `" . $app{"db"} . "`";
        $log->addLogLine($query) if $debug;
        $dbHandlerMaster->update($query);
    }
    else
    {
        $log->addLogLine("dealWithAppDatabase - You've asked me to do '$do' - not something I know how to do");
        exit;
    }

}

sub dealWithASVersion
{
    my %ret = ();

    mkdir $env{"ASPACE_VERSION_FOLDER"} if ( !( -d $env{"ASPACE_VERSION_FOLDER"}) );

    my $filename = getExternalPackageVersionFileName($env{"ASPACE_VERSION_FOLDER"}, $app{"as_version"});
    if($filename)
    {
        $app{"as_tarball"} = $filename;
    }
    else
    {
        $log->addLine("Downloading JSON..") if $debug;
        my $rawJSON = qx{curl --silent $archives_space_release_url};
        $json = JSON->new->allow_nonref;
        my @rawJSON = @{$json->decode( $rawJSON )};
        $log->addLine("Done. Parsing...") if $debug;
        my $latest = "";
        my %available_versions = ();
        foreach(@rawJSON)
        {
            my %this_entry = %{$_};
            if( ! $this_entry{"prerelease"})  ## We don't allow pre-release versions
            {
                my $this_name = lc $this_entry{"name"};
                $log->addLine($this_name . " Is NOT a pre release") if $debug;
                $available_versions{$this_name} = $archives_space_release_download_url . "/$this_name/archivesspace-" . $this_name . ".zip";
                $latest = $this_name if( ($this_name cmp $latest) > 0);
            }
        }
        my $version_dump = "";
        while ((my $key, my $val) = each(%available_versions))
        {
            $version_dump .= "$key";
            $version_dump .= " <--- latest " if ($key eq $latest);
            $version_dump .= "\n";
        }

        $app{"as_version"} = $latest if ($app{"as_version"} eq 'latest');
        if( !$available_versions{$app{"as_version"}} )
        {
            print "You've specified a version that is not available '" . $app{"as_version"} . "'\nThese are the versions that you can choose from:\n$version_dump";
            exit;
        }
        else
        {
            my $stored_file_path = $env{"ASPACE_VERSION_FOLDER"} . "/" . $app{"as_version"};
            mkdir $stored_file_path if ( !(-d $stored_file_path) );
            $filename = getExternalPackageVersionFileName($env{"ASPACE_VERSION_FOLDER"}, $app{"as_version"});
            if(!$filename)
            {
                my $cmd = "cd $stored_file_path && wget " . $available_versions{$app{"as_version"}};
                print "Downloading " . $app{"as_version"} . " from " .$available_versions{$app{"as_version"}} . "\n --> $stored_file_path\n";
                execSystemCMD($cmd);
                $filename = getExternalPackageVersionFileName($env{"ASPACE_VERSION_FOLDER"}, $app{"as_version"});
                # $filename = prepAspaceTarGZ($filename, $stored_file_path);
            }
            if($filename)
            {
                $app{"as_tarball"} = $filename;
            }
            else
            {
                print "Sorry, there was an error downloading ." . $app{"as_version"} . "\nFrom " . $available_versions{$app{"as_version"}} . "\nThese are the versions that you can choose from:\n$version_dump";
                exit;
            }
        }
    }
}

sub getExternalPackageVersionFileName
{
    my $root_path = shift;
    my $version = shift;
    my $ret;
    my $pwd = $root_path . "/" . $version;
    if( ( -d $pwd ) && ($version ne 'latest') )
    {
        opendir(DIR,"$pwd") or die "Cannot open $pwd\n";
        my @thisdir = readdir(DIR);
        closedir(DIR);
        foreach my $file (@thisdir)
        {
            if(($file ne ".") and ($file ne ".."))
            {
                if ( !(-d "$pwd/$file"))
                {
                    $ret = "$pwd/$file";
                    last;
                }
            }
        }
    }
    print "Found file: $ret\n" if $ret;
    return $ret;
}

sub prepAspaceTarGZ
{
    my $file = shift;
    my $dest_folder = shift;
    my $tar = Archive::Tar->new($file);
    my @files_in_archive = $tar->list_files;
    my $root_folder = @files_in_archive[0]; # whatever they named the root folder in the archive
    $root_folder =~ s/\/$//g;
    foreach(@files_in_archive)
    {
        my $this_archive_file = $_;
        my $dest = $this_archive_file;
        $dest =~ s/^$root_folder\/(.*)/archivesspace\/$1/g;
        $tar->rename($this_archive_file,$dest);
    }
    my $success = $tar->write( "$dest_folder/archivesspace.tar.gz", COMPRESS_GZIP );
    if($success)
    {
        unlink $file;
        return "$dest_folder/archivesspace.tar.gz";
    }
    else
    {
        print "Sorry, there was a problem when dealing with the raw archive $file:\n";
        print "Could not save $dest_folder/archivesspace.tar.gz\n";
        exit;
    }
}

sub figureASCompatibleVersion
{
    my $array_ref = shift;
    my %ar = %{$array_ref};
    my @keys = keys %ar;
    push(@keys, $app{"as_version"}); # injecting our key, letting perl sort feather our version amonst the rest of the keys
    @keys = sort @keys;
    my $result = 'none';
    foreach(@keys)
    {
        if($_ eq $app{"as_version"})
        {
            # exact version match
            return $ar{$_} if $ar{$_};
            # found our key, which means the previous loop was the compatible version
            return $ar{$result} if $ar{$result};
            # case when our key is the first (oldest). Nothing is compatible.
            return 'none';
        }
        $result = $_;
    }

    return 'none';
}

sub dealWithSOLRVersion
{
    my %ret = ();
    my $solr_version = figureASCompatibleVersion(\%aspace_solr_version_compatibility);
    return if $solr_version eq 'none'; # This version of archivesspace does not need external solr package

    mkdir $env{"SOLR_VERSION_FOLDER"} if ( !( -d $env{"SOLR_VERSION_FOLDER"}) );

    my $filename = getExternalPackageVersionFileName($env{"SOLR_VERSION_FOLDER"}, $app{"as_version"});
    if($filename)
    {
        $app{"solr_tarball"} = $filename;
    }
    else
    {   
        if( !$solr_download_url{$solr_version} )
        {
            print "I don't know where to download this version of solr: '$solr_version'\nPlease edit my definition at the top of this script.\n";
            exit;
        }
        else
        {
            my $stored_file_path = $env{"SOLR_VERSION_FOLDER"} . "/" . $app{"as_version"};
            mkdir $stored_file_path if ( !(-d $stored_file_path) );
            $filename = getExternalPackageVersionFileName($env{"SOLR_VERSION_FOLDER"}, $app{"as_version"});
            if(!$filename)
            {
                my $cmd = "cd $stored_file_path && wget " . $solr_download_url{$solr_version};
                print "Downloading solr $solr_version from " .$solr_download_url{$solr_version}. "\n --> $stored_file_path\n";
                execSystemCMD($cmd);
                $filename = getExternalPackageVersionFileName($env{"SOLR_VERSION_FOLDER"}, $app{"as_version"});
            }
            if($filename)
            {
                $app{"solr_tarball"} = $filename;
            }
            else
            {
                print "Sorry, there was an error downloading solr package $solr_version\nFrom " . $solr_download_url{$solr_version} . "\n";
                exit;
            }
        }
    }
}

sub readStorage
{
    my $url = shift;
    %app = (); #clear variable
    my $query = "SELECT ";
    $query .= "$_ ,\n" foreach(@master_db_columns);
    $query = substr($query,0,-2); # remove the last comma
    $query .= " FROM config WHERE url = '$url'";
    $log->addLogLine($query) if $debug;
    my @results = @{$dbHandlerMaster->query($query)};
    foreach(@results)
    {
        my @row = @{$_};
        for my $i(0..$#master_db_columns)
        {
            $app{@master_db_columns[$i]} = @row[$i];
        }
        last;
    }
}

sub saveStorage
{
    my $delete = shift;
    my $query = "";
    my $id = -1;
    my @vals = ();
    if($app{"id"})
    {
        $query = "SELECT id FROM config WHERE id = ".$app{"id"};
        $log->addLogLine($query) if $debug;
        my @results = @{$dbHandlerMaster->query($query)};
        $id = $results[0][0] || -1;
    }
    if($delete && $id > -1)
    {
        $query = "DELETE FROM config WHERE id = ?";
        push (@vals, $id);
    }
    else
    {
        $query = "INSERT INTO config (";
        $query = "UPDATE config set " if $id > -1;
        my $question_marks = "";
        foreach(@master_db_columns)
        {
            if($_ ne 'id')
            {
                $query .= "$_," if $id == -1;
                $query .= "$_ = ?," if $id > -1;
                $question_marks .= "? ,";
                push (@vals, $app{$_});
            }
        }
        $query = substr($query,0,-1); # remove the last comma
        $question_marks = substr($question_marks,0,-1); # remove the last comma
        $query .= ") VALUES (" if $id == -1;
        $query .= " WHERE ID = ?" if $id > -1;
        $query .= $question_marks .")" if ($id == -1);
        push (@vals,$id) if $id > -1;

        $log->addLogLine($query) if $debug;
        $log->addLogLine(Dumper(\@vals)) if $debug;
    }
    $dbHandlerMaster->updateWithParameters($query,\@vals);
}

sub setupASTarAndSettings
{

    my $do = shift || 'create';
    if($do eq 'create')
    {
        dealWithSOLRVersion();
        if( !(-d $app{"local_shared_folder"} ) )
        {
            mkdir $app{"local_shared_folder"};
            mkdir $app{"local_shared_folder"} . "/archivesspace";
        }
        if( !(-d $app{"local_shared_folder"} . "/archivesspace/launcher") )
        {
            # Put the tarball in place
            my $cmd = "cp " . $app{"as_tarball"} . " " . $app{"local_shared_folder"} . "/";
            execSystemCMD($cmd);

            # extract the tarball
            $cmd = "cd " . $app{"local_shared_folder"} . " && unzip archivesspace*.zip";
            execSystemCMD($cmd);
        }
        # Make sure the logs folder exists
        if( !(-d $app{"local_shared_folder"} . "/archivesspace/logs") )
        {
            $cmd = "mkdir " . $app{"local_shared_folder"} . "/archivesspace/logs";
            execSystemCMD($cmd);
        }

        # Make sure the data/tmp folder exists
        if( !(-d $app{"local_shared_folder"} . "/archivesspace/data/tmp") )
        {
            $cmd = "mkdir " . $app{"local_shared_folder"} . "/archivesspace/data/tmp";
            execSystemCMD($cmd);
        }

        # Make sure the log exists
        $cmd = "touch " . $app{"local_shared_folder"} . "/archivesspace/logs/archivesspace.out";
        execSystemCMD($cmd);

        # Put solr in place if needed
        if($app{"solr_tarball"})
        {
            $cmd = "cp '" . $app{"solr_tarball"} . "' '" . $app{"local_shared_folder"} . "/solrpack.tar.gz'";
            execSystemCMD($cmd);
            readFolder($app{"local_shared_folder"}, 1); # snapshot folder listing
            $cmd = "cd  '" .$app{"local_shared_folder"}  . "' && tar xzvf solrpack.tar.gz";
            execSystemCMD($cmd);
            my $folder = seeIfNewFolder($app{"local_shared_folder"});
            if($folder)
            {
                print "solr folder: $folder\n";
                # move it into a standard folder
                $cmd = "cd  '" .$app{"local_shared_folder"}  . "' && mv '$folder' solr_app";
                execSystemCMD($cmd);
            }
            else
            {
                print "There was a problem extracting the solr package,\n";
                print "I extracted this file: '" .$app{"local_shared_folder"}."/solrpack.tar.gz'\n";
                print "it didn't make a new folder\n";
                exit;
            }

            # put the archivesspace solr configurations in place
            $cmd = "cd  '" .$app{"local_shared_folder"}  . "' && mkdir -p solr_app/server/solr/configsets/archivesspace/conf && cp archivesspace/solr/*.* solr_app/server/solr/configsets/archivesspace/conf/";
            execSystemCMD($cmd);
        }

        # chown the whole thing
        $cmd = "chown -R " . $app{"local_username"} . ":" . $app{"local_username"} . " " . $app{"local_shared_folder"} . "/";
        execSystemCMD($cmd);

        setASConfig($app{"local_shared_folder"} . "/archivesspace/config/config.rb","frontend_proxy_url","https://" . $app{"staff_url"});
        setASConfig($app{"local_shared_folder"} . "/archivesspace/config/config.rb","public_proxy_url","https://" . $app{"url"});
        setASConfig($app{"local_shared_folder"} . "/archivesspace/config/config.rb","oai_proxy_url","https://" . $app{"url"} . "/oai");
    }
    elsif($do =~ m/delete/)
    {
        if( -d $app{"local_shared_folder"}  && length($app{"local_shared_folder"}) > 5 )
        {
            my $cmd = "rm -Rf " . $app{"local_shared_folder"};
            execSystemCMD($cmd);
        }
    }
}

sub setASConfig
{
    my $config_file = shift;
    my $variable = shift;
    my $setting = shift;
    my $conf_setting = "AppConfig[:$variable]";
    my $escaped_setting = $conf_setting;
    $escaped_setting =~ s/\[/\\[/g;
    $escaped_setting =~ s/\]/\\]/g;
    $escaped_setting =~ s/\:/\\:/g;
    my $fileRead = new Loghandler($config_file);
    my @lines = @{$fileRead->readFile($config_file)};
    my $ret = '';
    my $found_config_line = 0;
    while(@lines[0])
    {
        my $line = shift @lines;
        if(!$found_config_line)
        {
            if(!($line =~ m/^[\t\s]*#/g))
            {

                if( $line =~ m/^[\t\s]*$escaped_setting/g )
                {
                    $found_config_line = 1;
                    $line = "$conf_setting = \"$setting\"";
                }
            }
        }
        $line =~ s/[\n\t]*$//g;
        $ret .= "$line\n" if ($line ne '');
    }
    if(!$found_config_line) # Setting not found in the provided file - appending it to the bottom
    {
        $ret .= "$conf_setting = \"$setting\"";
    }
    $fileRead->truncFile($ret);
    return $ret;
}

sub editYML
{
    my $value = shift;
    my $yml_path = shift;
    my $file = shift;
    my $dothis = shift;
    my @path = split(/\//,$yml_path);

    my $fileRead = new Loghandler($file);
    my @lines = @{$fileRead->readFile($file)};
    my $depth = 0;
    my $ret = '';
    while(@lines[0])
    {
        my $line = shift @lines;
        if(@path[0])
        {
            @path[0] =~ s/!!!/\//g;
            my $preceed_space = $depth * 2;
            my $exp = '\s{'.$preceed_space.'}';
            $exp = '[^\s#]' if $preceed_space == 0;
            # print "testing $exp\n";
            if($line =~ m/^$exp.*/)
            {
                if($line =~ m/^[\s\-]*@path[0].*/)
                {
                    $depth++;
                    if(!@path[1]) ## we have arrived at the end of the array
                    {
                        # print "replacing '$line'\n";
                        my $t = @path[0];
                        if( $dothis eq 'replace' )
                        {
                            $line =~ s/^(.*?$t[^\s]*).*$/\1 $value/g;
                        }
                        elsif( $dothis eq 'create' )
                        {
                            my $newline = "";
                            # print "preceed space = $preceed_space\n";
                            my $i = 0;
                            $newline.=" " while($i++ < $preceed_space);
                            # print "new line = '$newline'\n";
                            $newline.=$value;
                            # print "new line = '$newline'\n";
                            $line.="$newline";
                        }
                        elsif( $dothis =~ m/delete/ )
                        {
                            $line='';
                        }
                        # print "now: '$line'\n";
                    }
                    shift @path;
                }
            }
        }
        $line =~ s/[\n\t]*$//g;
        $ret .= "$line\n" if ($line ne '');
    }

    return $ret;
}

sub readConfig
{
    my %ret = ();
    my $ret = \%ret;
    my $file = shift;

    my $confFile = new Loghandler($file);
    if(!$confFile->fileExists())
    {
        print "$file file does not exist\n";
        undef $confFile;
        return false;
    }

    my @lines = @{ $confFile->readFile() };
    undef $confFile;

    foreach my $line (@lines)
    {
        $line =~ s/\n//;  #remove newline characters
        my $cur = trim($line);
        my $len = length($cur);
        if($len>0)
        {
            if(substr($cur,0,1)ne"#")
            {
                my $Name, $Value;
                ($Name, $Value) = split (/=/, $cur);
                $$ret{trim($Name)} = trim($Value);
            }
        }
    }

    return \%ret;
}

sub readFile
{
    my $file = shift;
    my $trys=0;
    my $failed=0;
    my @lines;
    #print "Attempting open\n";
    if(-e $file)
    {
        my $worked = open (inputfile, '< '. $file);
        if(!$worked)
        {
            print "******************Failed to read file*************\n";
        }
        binmode(inputfile, ":utf8");
        while (!(open (inputfile, '< '. $file)) && $trys<100)
        {
            print "Trying again attempt $trys\n";
            $trys++;
            sleep(1);
        }
        if($trys<100)
        {
            #print "Finally worked... now reading\n";
            @lines = <inputfile>;
            close(inputfile);
        }
        else
        {
            print "Attempted $trys times. COULD NOT READ FILE: $file\n";
        }
        close(inputfile);
    }
    else
    {
        print "File does not exist: $file\n";
    }
    return \@lines;
}

sub createMasterDatabase
{

    my %answers = %{readConfig($local_my_cnf)};

    while ((my $key, my $val) = each(%answers))
    {
        $mysql_stuff{$key} = $answers{$key} || $mysql_stuff{$key};
    }

    # First connect without a database specified and make sure that the database exists
    $dbHandlerMaster = new DBhandler(0,$mysql_stuff{'host'},$mysql_stuff{'user'},$mysql_stuff{'password'},$mysql_stuff{'port'}||"3306","mysql");

    $log->addLogLine("DROP DATABASE $master_database") if $drop_master_db;
    $dbHandlerMaster->update("DROP DATABASE $master_database") if $drop_master_db;

    my @exists = @{$dbHandlerMaster->query("SELECT table_name FROM information_schema.tables WHERE table_schema RLIKE '$master_database' AND table_name RLIKE 'config'")};
    if(!$exists[0])
    {
        my $query = "CREATE DATABASE IF NOT EXISTS $master_database";
        $log->addLine($query) if $debug;
        $dbHandlerMaster->update($query);

        # Disconnect
        $dbHandlerMaster->breakdown();
        $dbHandlerMaster = undef;
        # now connect with the Database name
        $dbHandlerMaster = new DBhandler($master_database,$mysql_stuff{'host'},$mysql_stuff{'user'},$mysql_stuff{'password'},$mysql_stuff{'port'}||"3306","mysql");

        ##################
        # TABLES
        ##################
        $query = "CREATE TABLE IF NOT EXISTS config (
        id int not null auto_increment,\n";
        $query .= "active boolean default true,\n";
        $query .= "$_ varchar(100),\n" foreach(@master_db_columns);
        $query .= "PRIMARY KEY (id))";
        $log->addLine($query) if $debug;
        $dbHandlerMaster->update($query);
    }
    else
    {
        # now connect with the Database name
        $dbHandlerMaster = new DBhandler($master_database,$mysql_stuff{'host'},$mysql_stuff{'user'},$mysql_stuff{'password'},$mysql_stuff{'port'}||"3306","mysql");
    }

    push (@master_db_columns, 'id');
    push (@master_db_columns, 'active');
}

sub dockerComposeEditor
{
    my $path = shift;
    my $value = shift;
    my $do = shift;
    if($do eq 'create')
    {
        my $contents = editYML($value,$path,$docker_compose_file,$do);
        $contents =~ s/[\n\t]*$//g;
        my $composeWrite = new Loghandler($docker_compose_file);
        $value =~ s/\*/\\*/g;
        my $v = '\$';
        $value =~ s/$v/$v/g;
        $value =~ s/\{/\\{/g;
        $value =~ s/\}/\\}/g;
        $composeWrite->truncFile($contents) if ($contents =~ m/$value/);
        undef $composeWrite;
    }
    elsif($do =~ m/delete/)
    {
        my $contents = editYML($value,$path,$docker_compose_file,$do);
        $contents =~ s/[\n\t]*$//g;
        my $composeWrite = new Loghandler($docker_compose_file);
        $composeWrite->truncFile($contents);
        undef $composeWrite;
    }
    else
    {
        $log->addLogLine("dealWithLocalUserAccount - You've asked me to do '$do' - not something I know how to do");
        exit;
    }
}

sub trim
{
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

sub execSystemCMD
{
    my $cmd = shift;
    my $ignoreErrors = shift;
    print "executing $cmd\n" if $debug;
    $log->addLogLine($cmd);
    system($cmd) == 0;
    if(!$ignoreErrors && ($? == -1))
    {
        die "system '$cmd' failed: $?";
    }
}

sub execSystemCMDWithReturn
{
    my $cmd = shift;
    my $dont_trim = shift;
    my $ret;
    print "executing $cmd\n" if $debug;
    $log->addLogLine($cmd);
    open(DATA, $cmd.'|');
    my $read;
    while($read = <DATA>)
    {
        $ret .= $read;
    }
    close(DATA);
    return 0 unless $ret;
    $ret = substr($ret,0,-1) unless $dont_trim; #remove the last character of output.
    return $ret;
}

sub execDockerCMD
{
    my $docker_name = shift;
    my $docker_cmd = shift;
    my $as_root = shift;
    my $ignore = shift;
    my $docker_id = getDockerID($docker_name);
    my $root = "--user root";
    $root = '' if !$as_root;
    my $cmd = "docker exec $root $docker_id $docker_cmd";
    if($docker_id)
    {
        execSystemCMD($cmd) if $docker_id;
    }
    elsif(!$ignore)
    {
        print "We've encountered a problem executing a command on docker: '$docker_name' . \nIt doesn't exist!\n";
        exit;
    }
}

sub getAllMasterDBEntries
{
    my @ret = ();
    my $active_only = shift;
    $active_only = "WHERE active" if $active_only;
    my $query = "SELECT ";
    $query .= "$_ ,\n" foreach(@master_db_columns);
    $query = substr($query,0,-2); # remove the last comma
    $query .= " FROM config $active_only ORDER BY id";
    $log->addLogLine($query) if $debug;
    my @results = @{$dbHandlerMaster->query($query)};
    foreach(@results)
    {
        my @row = @{$_};
        my %this_one = ();
        for my $i(0..$#master_db_columns)
        {
            $this_one{@master_db_columns[$i]} = @row[$i];
        }
        push (@ret, \%this_one);
    }
    return \@ret;
}

sub generateNewVars
{
    my $url = shift;
    $app{"url"} = lc $url;
    $app{"db"} = $url;
    $app{"db"} =~ s/[_\.\-\/\\]//g;
    $app{"local_username"} = $url;
    # Truncate at 127 characters
    $app{"db"} = $app_db_prefix . $app{"db"};
    $app{"db"} = substr($app{"db"},0,$max_database_name_length) if length($app{"db"}) > $max_database_name_length;
    $app{"db_pass"} = generateRandomString(12);
    $app{"db_usr"} = $app{"db"};
    $app{"local_username"} =~ s/\./_/g;
    $app{"local_username"} = substr($app{"local_username"},-31) if length($app{"local_username"}) > 31;
    $app{"local_username"} = getNextLocalUsername($app{"local_username"});
    $app{"as_version"} = $as_version;
    $app{"staff_url"} = $staff_url || "staff.$url";
    $app{"active"} = 1;
    $app{"backup_folder"} = $env{"BACKUP_FOLDER"} . "/" . $app{"local_username"};
}

sub restoreData
{
    my $type = shift;
    my $backup_file = $restore_from if $restore_from;
    $backup_file = getLatestBackupFile() if !$backup_file;
    if( -f $backup_file )
    {
        if( $type eq 'db' )
        {
            my $from_tar = 0;
            if( $backup_file =~ m/\.tar/ ) # It's a tar or tar.gz
            {
                print "Reading TAR archive\n";
                my $tar = Archive::Tar->new($backup_file);
                my @sql_files = $tar->get_files( ($app{"local_username"} . ".sql") );
                if($#sql_files == -1) # didn't find a matching sql file with the exact name of this instance, let's loosen up
                {
                    print "Searching archive for sql files, it might be a minute\n";
                    my @dir_listing = $tar->list_files();
                    foreach(@dir_listing)
                    {
                        my @this_name = split(/\//,$_);
                        my $this_name = shift @this_name; # expecting sql files to be in the root
                        if( lc($this_name) =~ m/\.sql$/ )
                        {
                            my $answer = promptUser("A fuzzy match was found in the tar file: $this_name\n Restore that? y/n");
                            @sql_files = $tar->get_files( $_ ) if($answer =~ m/^ye?s?$/i);
                            last if($answer =~ m/^ye?s?$/i);
                        }
                    }
                }
                foreach(@sql_files)
                {
                    print "Extracting temp sql file from $backup_file\n";
                    last if $_->extract($app{"backup_folder"} . "/restoring.sql");
                    print "Failed to extract the sql file, hopefully there is a reason above :)\n";
                    exit;
                }
                if( -f $app{"backup_folder"} . "/restoring.sql" )
                {
                    $from_tar = 1;
                    $backup_file = $app{"backup_folder"} . "/restoring.sql";
                }
                else
                {
                    promptUser("Couldn't find a suitable database file in '$backup_file'.");
                }
                undef $tar;
            }
            if( $backup_file =~ m/\.sql/ )
            {
                my $cmd = "mysql " . $app{"db"} . " < $backup_file";
                print boxText("Restoring DB...");
                execSystemCMD($cmd);
                unlink $backup_file if $from_tar;
            }
            else
            {
                promptUser("Sorry, I don't know how to restore database file: '$backup_file'.");
            }
        }
        elsif( $type eq 'folder' )
        {
            if( $backup_file =~ m/\.tar/ ) # It's a tar or tar.gz
            {
                my $tar = Archive::Tar->new($backup_file);
                my @archive_space_files = $tar->list_files();
                mkdir $app{"local_shared_folder"} if ( !(-d $app{"local_shared_folder"}));
                $tar->setcwd($app{"local_shared_folder"});
                my @extract_these = ();
                foreach(@archive_space_files)
                {
                    push (@extract_these, $_) if($_ =~ m/^archivesspace/);
                }
                if( $#extract_these > -1 )
                {
                    print "Extracting $#extract_these files\n";
                    $tar->extract(@extract_these);
                    my $pid = $app{"local_shared_folder"} . "/archivesspace/data/.archivesspace.pid";
                    unlink $pid if (-f $pid);
                }
                else
                {
                    promptUser("No suitable folder 'archivesspace' found within '$backup_file'.");
                }
                undef @extract_these;
                undef $tar;
            }
            elsif( !($backup_file =~ m/\.sql/ ) )
            {
                promptUser("Sorry, I don't know how to restore folder from file: '$backup_file'.\nYour getting stock.");
            }
        }
        else
        {
            promptUser("Sorry, I don't know how to restore '$type'.");
        }
    }
    else
    {
        promptUser("Sorry, this restore file '$backup_file' doesn't exist!");
    }
}

sub promptUser
{
    my $prompt = shift;
    print boxText("$prompt");
    print "\n >";
    my $ret = <STDIN>;
    $ret =~ s/\n*$//;
    return $ret;
}

sub getNextLocalUsername
{
    my $seed = shift;
    my $query = "select local_username from config";
    $log->addLogLine($query) if $debug;
    my @results = @{$dbHandlerMaster->query($query)};
    my @used = ();
    foreach(@results)
    {
        my @row = @{$_};
        push(@used, @row[0]);
    }
    my $exists = 1;
    my $ret = $seed;
    my $append = 0;
    while($exists)
    {
        $exists = 0;
        foreach(@used)
        {
            if($_ eq $ret)
            {
                $append++;
                $ret = $seed . $append;
                $exists = 1;
                $ret = substr($ret,-31) if length($ret) > 31;
            }
        }
    }
    return $ret;
}

sub getLatestBackupFile
{
    $ret = 0;
    my @files = ();
    if(-d $app{"backup_folder"})
    {
        opendir(DIR, $app{"backup_folder"}) or die "Cannot open " . $app{"backup_folder"} . "\n";
        my @thisdir = readdir(DIR);
        closedir(DIR);
        foreach my $file (@thisdir)
        {
            if(($file ne ".") and ($file ne ".."))
            {
                if ( !(-d $app{"backup_folder"} . "/$file"))
                {
                    ## make sure it's a tar.gz file, Anything is is not considered a backup file
                    push (@files, $app{"backup_folder"}  . "/$file") if( $file =~ m/\.tar\.gz$/ );
                }
            }
        }
    }
    @files = sort @files;
    $ret = pop @files if ($#files > -1);
    return $ret;
}

sub rotateBackups
{
    if($action eq 'backup') #rotate only when specifically running backup routine.
    {
        if(-d $env{"BACKUP_FOLDER"})
        {
            opendir(DIR, $env{"BACKUP_FOLDER"}) or die "Cannot open " . $env{"BACKUP_FOLDER"} . "\n";
            my @thisdir = readdir(DIR);
            closedir(DIR);
            foreach my $app_folder (@thisdir)
            {
                if(($app_folder ne ".") and ($app_folder ne ".."))
                {
                    if ( (-d $env{"BACKUP_FOLDER"} . "/$app_folder"))
                    {
                        my @app_files = ();
                        opendir(DIR, $env{"BACKUP_FOLDER"} . "/$app_folder") or die "Cannot open " . $env{"BACKUP_FOLDER"} . "/$app_folder\n";
                        my @appdir = readdir(DIR);
                        closedir(DIR);
                        foreach my $app_file (@appdir)
                        {
                            my $full_path = $env{"BACKUP_FOLDER"} . "/$app_folder/$app_file";
                            if(($app_file ne ".") and ($app_file ne "..") && !(-d $full_path))
                            {
                                ## make sure it's a tar.gz file, Anything is is not considered a backup file
                                push (@app_files, $full_path) if( $app_file =~ m/\.tar\.gz$/ );
                            }
                        }
                        @app_files = sort(@app_files);
                        my $remove = ($#app_files+1) - $backup_retention_count;
                        $remove = 0 if($#app_files < 1); # Always keep the last backup
                        while($remove > 0)
                        {
                            print "Deleting old backup " . $env{"BACKUP_FOLDER"} . "/$app_folder" . "\n";
                            unlink shift @app_files;
                            $remove--;
                        }
                    }
                }
            }
        }
    }
}

sub syncRunningContainersToDB
{
    my @all = @{getAllMasterDBEntries()};
    foreach(@all)
    {
        %app = %{$_};
        my $name = $app{"local_username"};
        my $cmd = "docker ps -f name=\"$name\" --format \"{{.ID}}\"";
        my $running = execSystemCMDWithReturn($cmd);
        print "$name container = $running\n" if $debug;
        if(!$running && $app{"active"})
        {
            $app{"active"} = 0;
            saveStorage();
        }
        elsif($running && !$app{"active"})
        {
            $app{"active"} = 1;
            saveStorage();
        }
        dealWithDockerCompose("delete");  ## clean any entries that might already exist
        dealWithDockerCompose("create") if $app{"active"};
    }
    undef %app;
}

sub generateRandomString
{
    my $length = shift;
    my $i=0;
    my $ret="";
    my @letters = ('a','b','c','d','e','f','g','h','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z');
    my $letterl = $#letters;
    my @sym = ('!',',','_');
    my $syml = $#sym;
    my @nums = (1,2,3,4,5,6,7,8,9,0);
    my $nums = $#nums;
    my @all = ([@letters],[@sym],[@nums]);
    while($i<$length)
    {
        #print "first rand: ".$#all."\n";
        my $r = int(rand($#all+1));
        #print "Random array: $r\n";
        my @t = @{@all[$r]};
        #print "rand: ".$#t."\n";
        my $int = int(rand($#t + 1));
        #print "Random value: $int = ".@{$all[$r]}[$int]."\n";
        $ret.= @{$all[$r]}[$int];
        $i++;
    }

    return $ret;
}

sub makeEvenWidth  #line, width
{
    my $ret;

    if($#_+1 !=2)
    {
        return;
    }
    $line = @_[0];
    $width = @_[1];
    #print "I got \"$line\" and width $width\n";
    $ret=$line;
    if(length($line)>=$width)
    {
        $ret=substr($ret,0,$width);
    }
    else
    {
        while(length($ret)<$width)
        {
            $ret=$ret." ";
        }
    }
    #print "Returning \"$ret\"\nWidth: ".length($ret)."\n";
    return $ret;

}

sub boxText
{
    my $text = shift;
    my $hChar = shift || '#';
    my $vChar = shift || '|';
    my $padding = shift || 4;
    my $ret = "";
    my $longest = 0;
    my @lines = split(/\n/,$text);
    length($_) > $longest ? $longest = length($_) : '' foreach(@lines);
    my $totalLength = $longest + (length($vChar)*2) + ($padding *2) + 2;
    my $heightPadding = ($padding / 2 < 1) ? 1 : $padding / 2;

    # Draw the first line
    my $i = 0;
    while($i < $totalLength)
    {
        $ret.=$hChar;
        $i++;
    }
    $ret.="\n";
    # Pad down to the data line
    $i = 0;
    while( $i < $heightPadding )
    {
        $ret.="$vChar";
        my $j = length($vChar);
        while( $j < ($totalLength - (length($vChar))) )
        {
            $ret.=" ";
            $j++;
        }
        $ret.="$vChar\n";
        $i++;
    }

    foreach(@lines)
    {
        # data line
        $ret.="$vChar";
        $i = -1;
        while($i < $padding )
        {
            $ret.=" ";
            $i++;
        }
        $ret.=$_;
        $i = length($_);
        while($i < $longest)
        {
            $ret.=" ";
            $i++;
        }
        $i = -1;
        while($i < $padding )
        {
            $ret.=" ";
            $i++;
        }
        $ret.="$vChar\n";
    }
    # Pad down to the last
    $i = 0;
    while( $i < $heightPadding )
    {
        $ret.="$vChar";
        my $j = length($vChar);
        while( $j < ($totalLength - (length($vChar))) )
        {
            $ret.=" ";
            $j++;
        }
        $ret.="$vChar\n";
        $i++;
    }
     # Draw the last line
    $i = 0;
    while($i < $totalLength)
    {
        $ret.=$hChar;
        $i++;
    }
    $ret.="\n";
    return $ret;
}

sub seeIfNewFolder
{
    my $pwd = shift;
    my @files = @{readFolder($pwd)};
    foreach(@files)
    {
        if(!$foldersOnDisk{$_})
        {
            print "Detected new folder: $_\n";
            return  $_;
        }
    }
    return 0;
}

sub readFolder
{
    my $pwd = shift;
    my $init = shift || 0;

    %foldersOnDisk = () if $init;
    opendir(DIR,$pwd) or die "Cannot open $pwd\n";
    my @thisdir = readdir(DIR);
    closedir(DIR);
    foreach my $file (@thisdir) 
    {
        if( ($file ne ".") && ($file ne "..") && !($file =~ /\.part/g))  # ignore firefox "part files"
        {
            print "Checking: $file\n";
            if (-d "$pwd/$file")
            {
                push(@files, "$file");
                if($init)
                {
                    $foldersOnDisk{$file} = 1;
                }
            }
        }
    }
    return \@files;
}

sub cleanup
{
    print "Caught kill signal, please don't kill me, I need to cleanup\ncleaning up....\n";
    sleep 1;
    if($action eq 'create' && $app{"local_username"} && length($app{"local_username"}) > 0)
    {
        $action = "delete";
        dealWithDockerService($action);
        dealWithProxy($action);
        dealWithDockerCompose($action);
        dealWithAppDatabase($action);
        dealWithLocalUserAccount($action);
        $app{"active"} = 0;
        saveStorage();
    }
    print "done\n";
    exit 0;
}

sub DESTROY
{
    $dbHandlerMaster->breakdown if($dbHandlerMaster);
    undef $dbHandlerMaster;
    exit;
}

# exit 0;
