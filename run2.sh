#!/bin/bash

#if no koha instance name was provided, then set it as "default"
export KOHA_INSTANCE=${KOHA_INSTANCE:-default}

export KOHA_INTRANET_PORT=${KOHA_INTRANET_PORT:-8081}
export KOHA_OPAC_PORT=${KOHA_OPAC_PORT:-8080}
export USE_MEMCACHED=${USE_MEMCACHED:-yes}
export MEMCACHED_SERVERS=${MEMCACHED_SERVERS:-memcached:11211}
export MYSQL_SERVER=${MYSQL_SERVER:-db}
export MYSQL_PASSWORD=${MYSQL_PASSWORD:-$(pwgen -s 15 1)}
export ZEBRA_MARC_FORMAT=${ZEBRA_MARC_FORMAT:-marc21}


envsubst < ./templates/koha-sites.conf > /etc/koha/koha-sites.conf
envsubst < ./templates/koha-conf-site.xml.in > /etc/koha/koha-conf-site.xml.in
envsubst < ./templates/apache-shared-intranet-plack.conf > /etc/koha/apache-shared-intranet-plack.conf
envsubst < ./templates/apache-shared-opac-plack.conf > /etc/koha/apache-shared-opac-plack.conf
echo -n "${KOHA_INSTANCE}:koha_${KOHA_INSTANCE}:${MYSQL_PASSWORD}:koha_${KOHA_INSTANCE}:${MYSQL_SERVER}" > /etc/koha/passwd

if [ ! -f "/usr/share/koha/bin/koha-functions.sh" ]
then
    echo "koha-functions should be present"
    exit 1
fi

source /usr/share/koha/bin/koha-functions.sh

if [ "${USE_BACKEND}" = "1" ] || [ "${USE_BACKEND}" = "true" ]
then
    until mysql --user=root --password=${MYSQL_ROOT_PASSWORD} --host=${MYSQL_SERVER} mysql -e "select 1" > /dev/null 2>&1; do
        echo "Waiting for database to be ready"
        sleep 1;
    done

    echo "Database ready"

    #if there is no /var/lib/koha/<instance> directory, then we must install
    if ! is_instance ${KOHA_INSTANCE} || [ ! -f "/etc/koha/sites/${KOHA_INSTANCE}/koha_conf.xml" ]
    then
        echo "Creating instance ${KOHA_INSTANCE}"
        #try to connect to database
        mysql --user=root --password=${MYSQL_ROOT_PASSWORD} --host=${MYSQL_SERVER} koha_${KOHA_INSTANCE} -e "select 1" > /dev/null 2>&1

        if [ "$?" = "1" ]
        then
            #Database not created
            echo "Creating database koha_${KOHA_INSTANCE}"
            mysql --user=root --password=${MYSQL_ROOT_PASSWORD} --host=${MYSQL_SERVER} mysql << EOF
    CREATE DATABASE \`koha_${KOHA_INSTANCE}\`;
    CREATE USER \`koha_${KOHA_INSTANCE}\`@'*' IDENTIFIED BY '${MYSQL_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`koha_${KOHA_INSTANCE}\`.* TO \`koha_${KOHA_INSTANCE}\`@'*';
    FLUSH PRIVILEGES;   
EOF
        fi
    fi
        
    envsubst < ./templates/supervisor/plack.conf > /etc/supervisor/conf.d/plack.conf

    if [ "${OVERRIDE_SYSPREF_SearchEngine}" != "Elasticsearch" ]
    then
        envsubst < ./templates/supervisor/zebra.conf > /etc/supervisor/conf.d/zebra.conf
    else
        koha-elasticsearch --rebuild -p $(grep -c ^processor /proc/cpuinfo) ${KOHA_INSTANCE} &
    fi

    for i in $(koha-translate -l)
    do
        if [ "${KOHA_LANGS}" = "" ] || ! echo "${KOHA_LANGS}"|grep -q -w $i
        then
            echo "Removing language $i"
            koha-translate -r $i
        else
            echo "Checking language $i"
            koha-translate -c $i
        fi
    done

    if [ "${KOHA_LANGS}" != "" ]
    then
        echo "Installing languages"
        LANGS=$(koha-translate -l)
        for i in $KOHA_LANGS
        do
            if ! echo "${LANGS}"|grep -q -w $i
            then
                echo "Installing language $i"
                koha-translate -i $i
            else
                echo "Language $i already present"
            fi
        done
    fi
fi

if ! is_instance ${KOHA_INSTANCE} || [ ! -f "/etc/koha/sites/${KOHA_INSTANCE}/koha_conf.xml" ]
then
    echo "Executing koha-create for instance ${KOHA_INSTANCE}"
    koha-create --use-db ${KOHA_INSTANCE} | true
else
    echo "Creating directories structure"
    koha-create-dirs ${KOHA_INSTANCE}
fi

if [ "$USE_SIP" = "1" ] || [ "$USE_SIP" = "true" ]
then
    echo "Configuring SIPServer"
    SIP_CONF_ACCOUNTS=''
    for ac in $SIP_ACCOUNTS
    do
        SIP_PWD='SIP_${ac}_PWD'
        SIP_DLTR='SIP_${ac}_DLTR'
        SIP_ERR='SIP_${ac}_ERR'
        SIP_LIB='SIP_${ac}_LIB'
        SIP_CONF_ACCOUNTS=$(cat << EOF
        ${SIP_CONF_ACCOUNTS}
        <login  id=\"${ac}\" password="${!SIP_PWD}"
                delimiter="${!SIP_DLTR:-|}" error-detect="${!SIP_ERR:-enabled}" 
                institution="${!SIP_LIB}"
        />
EOF
)
    done

    SIP_CONF_LIBS=''
    for lib in $SIP_LIBS
    do
        SIP_IMPL='SIP_${lib}_IMPL'
        SIP_PARAMS='SIP_${lib}_PARAMS'
        SIP_CI='SIP_${lib}_CI'
        SIP_RNW='SIP_${lib}_RNW'
        SIP_CO='SIP_${lib}_CO'
        SIP_SU='SIP_${lib}_SU'
        SIP_OL='SIP_${lib}_OL'
        SIP_TO='SIP_${lib}_TO'
        SIP_RET='SIP_${lib}_RET'
        SIP_CONF_LIBS=$(cat << EOF
        ${SIP_CONF_LIBS}
        <institution id="${lib}" implementation="${!SIP_IMPL:-ILS}" parms="${!SIP_PARAMS}">
         <policy checkin="${!SIP_CI:-true}" renewal="${!SIP_RNW:-true}" checkout="${!SIP_CO:-true}"
                 status_update="${!SIP_SU:-false}" offline="${!SIP_OL:-false}"
                 timeout="${!SIP_TO:-100}"
                 retries="${!SIP_RET:-5}" />
        </institution>
EOF
)
    done

    envsubst < ./templates/SIPconfig.xml > /etc/koha/sites/${KOHA_INSTANCE}/SIPconfig.xml
    envsubst < ./templates/supervisor/sip.conf > /etc/supervisor/conf.d/sip.conf
fi

envsubst < ./templates/supervisor/supervisord.conf > /etc/supervisor/supervisord.conf

if [ "${USE_APACHE2}" = "1" ] || [ "${USE_APACHE2}" = "true" ]
then
    koha-plack --enable ${KOHA_INSTANCE}
    envsubst < ./templates/supervisor/apache2.conf > /etc/supervisor/conf.d/apache2.conf
fi

if [ "${USE_CRON}" = "1" ] || [ "${USE_CRON}" = "true" ]
then
    envsubst < ./templates/supervisor/cron.conf > /etc/supervisor/conf.d/cron.conf
fi

if [ "${USE_Z3950}" = "1" ] || [ "${USE_Z3950}" = "true" ]
then
    koha-z3950-responder --enable $KOHA_INSTANCE
    envsubst < ./templates/supervisor/z3950.conf > /etc/supervisor/conf.d/z3950.conf
fi

service apache2 stop
koha-indexer --stop ${KOHA_INSTANCE}
koha-zebra --stop ${KOHA_INSTANCE}

supervisord -c /etc/supervisor/supervisord.conf
