#/bin/bash
# credits: https://github.com/alexchanwk/docker-archivesspace/blob/master/entrypoint.sh

# AS_EXT_PLUGIN_URL_PREFIX="ASPACE_EXT_PLUGIN_URL_"
SETUP_LOG_FILE_NAME="setup.log"
SETUP_LOG_FILE="${ASHOME}/${SETUP_LOG_FILE_NAME}"
MYSQL_CNF_FILE=~/.my.cnf

USE_MYSQL="Y"
ASPACE_SKIP_SETUP_DATABASE="N"
ASPACE_SKIP_START_SERVER="N"

cd ${ASHOME}

source config.env

if [[ ! -d "${AS}/launcher" ]]
then
    if [ -f archivesspace*.zip ]; then sudo unzip archivesspace*.zip ; fi && \
      mv -f archivesspace*.zip /var/tmp/ && \
      mkdir ${AS}/logs && touch ${AS}/logs/archivesspace.out 
fi

# Download MySQL Java connector if needed.
find $AS/lib -name "mysql-connector*.jar" -print | egrep '.*' || \
  curl -LsO https://repo1.maven.org/maven2/mysql/mysql-connector-java/${MYSQLJ_VERSION}/mysql-connector-java-${MYSQLJ_VERSION}.jar
if [ -f mysql-connector*.jar ]; then sudo mv -f mysql-connector*.jar ${AS}/lib; fi

sudo chown -R ${ASUSER}:${ASUSER} ${ASHOME}

if [[ ! -z "$SKIP_SETUP_DATABASE" ]]
then
    if [[ "$SKIP_SETUP_DATABASE" == "Y" ]]
    then
        ASPACE_SKIP_SETUP_DATABASE="Y"
    fi
fi

if [[ ! -z $SKIP_START_SERVER ]] 
then
    if [ "${SKIP_START_SERVER}" == "Y" ]
    then
        ASPACE_SKIP_START_SERVER="Y"
    fi
fi

if [[ -f "${ASHOME}/mysql-configured" ]]
then
    USE_MYSQL="N"
fi

if [[ -z "${MYSQL_HOST}" || -z "${MYSQL_DATABASE}" || -z "${MYSQL_USER}" || -z "${MYSQL_PASSWORD}" ]]
then
    USE_MYSQL="N"
    echo | tee -a ${SETUP_LOG_FILE}
    echo "Startup: Complete credentials missing for MySQL" | tee -a ${SETUP_LOG_FILE}
    echo "host: ${MYSQL_HOST}; db: ${MYSQL_DATABASE}; user: ${MYSQL_USER}; pass: ${MYSQL_PASSWORD}" | tee -a ${SETUP_LOG_FILE}
fi

if [[ ${USE_MYSQL} == "Y" ]]
then
    echo | tee -a ${SETUP_LOG_FILE}
    echo "Startup: Complete credentials found for MySQL" | tee -a ${SETUP_LOG_FILE}

    # Configure MYSQL Client
    if [[ ! -f ${MYSQL_CNF_FILE} ]]
    then
        echo "[client]" > ${MYSQL_CNF_FILE}
        echo "host=${MYSQL_HOST}" >> ${MYSQL_CNF_FILE}
        echo "#database=${MYSQL_DATABASE}" >> ${MYSQL_CNF_FILE}
        echo "user="${MYSQL_USER} >> ${MYSQL_CNF_FILE}
        echo "password="${MYSQL_PASSWORD} >> ${MYSQL_CNF_FILE}
    fi
fi

# MYSQL configurations
if [[ $USE_MYSQL == "Y" && $ASPACE_SKIP_SETUP_DATABASE == "N" ]]
then

    echo | tee -a ${SETUP_LOG_FILE}
    echo "Configuring MySQL with CREATE DATABASE statement"| tee -a ${SETUP_LOG_FILE}
    echo "mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -e \"CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE} DEFAULT CHARACTER SET UTF8;\"" | tee -a ${SETUP_LOG_FILE}

    mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} -e "CREATE DATABASE ${MYSQL_DATABASE} DEFAULT CHARACTER SET UTF8;" 
    touch ${ASHOME}/mysql-configured
fi

# Generate ArchivesSpace config file on first startup 
# Database connection string
if [[ ${USE_MYSQL} == "Y" ]]
then
    echo "AppConfig[:db_url] = \"jdbc:mysql://${MYSQL_HOST}:3306/${MYSQL_DATABASE}?user=${MYSQL_USER}&password=${MYSQL_PASSWORD}&useUnicode=true&characterEncoding=UTF-8\""

    cat << ENDL >> ${AS}/config/config.rb
AppConfig[:db_url] = "jdbc:mysql://${MYSQL_HOST}:3306/${MYSQL_DATABASE}?user=${MYSQL_USER}&password=${MYSQL_PASSWORD}&useUnicode=true&characterEncoding=UTF-8"
ENDL
fi


# untested
# Add custom plugins
# for env in $(compgen -v)
# do
#     if [[ ${env} == ${AS_EXT_PLUGIN_URL_PREFIX}* ]]
#     then
#         PLUGIN_NAME_UNNORMALIZED=${env:22}
#         PLUGIN_NAME=${PLUGIN_NAME_UNNORMALIZED//_/-}
#         PLUGIN_URL=`echo ${!env} | xargs`

#         echo "Adding external plugin ${PLUGIN_NAME} from ${PLUGIN_URL}..."
#         if [[ ! -z ${PLUGIN_NAME} && ! -z ${PLUGIN_URL} ]]
#         then
#             cd ${AS}/plugins
#             rm -rf ${PLUGIN_NAME}
#             mkdir ${PLUGIN_NAME}
#             cd ${PLUGIN_NAME}
#             wget -nv -O ${PLUGIN_NAME}.tar.gz ${PLUGIN_URL}
#             if [ -f ${PLUGIN_NAME}.tar.gz ]
#             then
#                 tar -zxf ${PLUGIN_NAME}.tar.gz
#                 rm -f ${PLUGIN_NAME}.tar.gz
#             fi
#         fi
#     fi
# done


if [[ $USE_MYSQL == "Y" ]]
then
    # ArchivesSapce initial database setup
    if [[ $ASPACE_SKIP_SETUP_DATABASE == "N" ]]
    then
      echo "Setup Database..." | tee -a ${SETUP_LOG_FILE}
      ${AS}/scripts/setup-database.sh
    fi
else
    DEMO_DB_LS=`ls ${AS}/data/archivesspace_demo_db/ | wc -l`
    if [[ ${DEMO_DB_LS} > 0 ]]
    then
        echo "Table already exists in database! Database restore skipped!" | tee -a ${SETUP_LOG_FILE}
        echo
    # else
    #     echo "Restoring database from latest backup..." | tee -a ${SETUP_LOG_FILE}
        # /restore.sh
    fi
fi

# Clean up .my.cnf
#if [[ $USE_MYSQL == "Y" ]]
#then
#    if [[ -f ${MYSQL_CNF_FILE} ]]
#    then
#        rm -f ${MYSQL_CNF_FILE}
#    fi
#fi

END_TIME=`date "+%Y-%m-%d %H:%M:%S"`
echo "ArchivesSpace setup completed at ${END_TIME} !" | tee -a ${SETUP_LOG_FILE}
echo | tee -a ${SETUP_LOG_FILE}


# Start sendmail
sudo /etc/init.d/sendmail start

# Start ArchivesSpace
if [[ "${ASPACE_SKIP_START_SERVER}" == "Y" ]]
then
    echo "Start ArchivesSpace server skipped!"
    echo
else
    echo "Starting ArchivesSpace server..."
    echo
    ${AS}/archivesspace.sh start
fi

#while ! tail -f ${AS}/logs/archivesspace.out ; do sleep 5 ; done
