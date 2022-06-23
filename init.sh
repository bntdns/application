#!/bin/bash
#
# Licensed Materials - Property of IBM Corp.
# IBM UrbanCode Build
# IBM UrbanCode Deploy
# IBM UrbanCode Release
# (c) Copyright IBM Corporation 2017. All Rights Reserved.
#
# U.S. Government Users Restricted Rights - Use, duplication or disclosure restricted by
# GSA ADP Schedule Contract with IBM Corp.
#

# exit this script if any sub-shells or commands fail
set -x
set -e

# Pull in shell function definitions used later
source /usr/local/bin/ucd-utils.sh

APPDATA=${UCD_HOME}/appdata
if [ -e ${APPDATA}/enable-debug ] ; then
        set -x
        export DEBUG_ENABLED="true"
fi

# Check that DB_TYPE, DB_NAME, etc have been provided
if [ ! db_env_vars_set ] ; then
    echo "Missing required input variables."
    exit 1
fi

# Set the DATABASE_CONNECTION_URL and JDBC_DRIVER_CLASS
set_jdbc_variables
if [ $? -ne 0 ] ; then
    echo "Failed to set JDBC variables."
    exit 1
fi

if [ ! ${UCD_WSS_PORT} ] ; then
    export UCD_WSS_PORT=7919
fi
if [ ! ${UCD_SECURE_PORT} ] ; then
    export UCD_SECURE_PORT=8443
fi
if [ ! ${UCD_PORT} ] ; then
    export UCD_PORT=8080
fi
if [ ! ${UCD_SERVER_NAME} ] ; then
    export UCD_SERVER_NAME=$(hostname)
fi
if [ ! ${HEADLESS_SVC_NAME} ] ; then
    export HEADLESS_SVC_NAME=${UCD_SERVER_NAME%-*}-hl
fi

echo "UCD_VENDOR_NAME_ENV is ${UCD_VENDOR_NAME_ENV}"
if [ -z "${JAVA_HOME}" ] ; then
    export JAVA_HOME=/etc/alternatives/jre
    export PATH=$JAVA_HOME/bin:$PATH
fi
echo "JAVA_HOME is ${JAVA_HOME}"
echo "PATH is ${PATH}"

if [[ -z "${UCD_WEB_URL}" ]] ; then
    echo "Set UCD_WEB_URL variable from openshift route if available"
    UCD_WEB_URL=$(get_route_hostname)
    if [ -z "${UCD_WEB_URL}" ] ; then
        echo "Set UCD_WEB_URL variable from ingress if available"
        UCD_WEB_URL=$(get_ingress_hostname)
        if [ -z "${UCD_WEB_URL}" ] ; then
            echo "Set UCD_WEB_URL variable from loadbalancer if available"
            UCD_WEB_URL=$(get_loadbalancer_hostname)
        fi
    fi
else
    echo "Using UCD_WEB_URL passed into the init container as environment variable:  ${UCD_WEB_URL}"
fi

# If not using derby, ensure the jdbc jars are mounted and accessible for both prod-0 and dfe-0 instances of the server
if [ "${HOST_NAME:(-2)}" = "-0" ] ; then
    # run the user provided script, if available
    if [ -f /tmp/user-script/script.sh ]; then
        echo "Running /tmp/user-script/script.sh"
        cd /tmp     # To allow writing JDBC files to current directory
        cp /tmp/user-script/script.sh .   # Since exe as non-root not allowed
        bash ./script.sh

        # In case we enabled debug logging via the configmap script
        if [ -e ${APPDATA}/enable-debug ] ; then
            set -x
            export DEBUG_ENABLED="true"
        fi
        cd -
    fi

    if [ "${DB_TYPE}" != "derby" ] ; then
        if [ ! -d ${UCD_HOME}/lib/ext ]; then
            mkdir ${UCD_HOME}/lib/ext
        fi
        ls ${UCD_HOME}/ext_lib/*.jar
        if [ $? -eq 0 ] ; then
            cp ${UCD_HOME}/ext_lib/*.jar ${UCD_HOME}/lib/ext
            cp ${UCD_HOME}/ext_lib/*.jar ${UCD_INSTALL}/lib/ext
        else
            echo "Persistent storage holding JDBC libraries was not found. Database connections will likely fail."
        fi
    fi
fi

# First UCD server instance will do most of the initialization.  Don't want to do all for "secondary" instances.
if [ "${HOST_NAME:(-6)}" = "prod-0" ] ; then
    # Do any required migration of keystore files so they can be accessed with
    # the current JRE.  This is only needed if we are upgrading an existing
    # instance.  Allow KeystoreUtils to fail without exiting init.sh
    if [ -f ${APPDATA}/conf/encryption.keystore ] ; then
        set +e
        java -cp "/usr/local/lib/KeystoreUtils.jar:${UCD_HOME}/lib/utils.jar:${UCD_HOME}/lib/commons-codec.jar:${UCD_HOME}/lib/log4j.jar:${UCD_HOME}/lib/commons-lang3.jar:${UCD_HOME}/lib/cryptkeystore.jar:${UCD_HOME}/lib/keytoolhelper.jar:${UCD_HOME}/lib/bcprov-jdk15on.jar:${UCD_HOME}/lib/bcpkix-jdk15on.jar" KeystoreUtils migrate ${UCD_HOME} ${HOST_NAME:(-1)}
        rc=$?
        set -e
        if [ ${rc} -ne 0 ]; then
            echo "Problems migrating keystore files!"
            exit 1
        fi
    fi

    # check if the database has already been initialized
    echo "Checking to see if the database has already been initialized. You may see an error or warning if the database has not been initialized."
    if [ "${DEBUG_ENABLED}" == "true" ] ; then
        echo "**** ENV variables: ****"
        env | sort
        echo
    fi
    # allow UcdDbUtils to fail without exiting init.sh
    set +e
    java -cp "/usr/local/lib/UcdDbUtils.jar:${UCD_HOME}/lib/ext/*:${UCD_HOME}/lib/ext/mysql-jdbc.jar:${UCD_HOME}/lib/derbyclient.jar:${UCD_HOME}/lib/CommonsUtil.jar:${UCD_HOME}/lib/commons-codec.jar:${UCD_HOME}/lib/log4j.jar:${UCD_HOME}/lib/commons-lang3.jar:" UcdDbUtils chkDbInit null "${UCD_HOME}/" "${DB_TYPE}" "${DB_NAME}" "${DB_USER}" "${DB_PASSWORD}" "${DB_TCP_URL}" "${DB_TCP_PORT}" "${DB_JDBC_CONN_URL}"
    rc=$?
    set -e

    # Possible return code values from UcdDbUtils when performing DB initialization check:
    #   DB_INITIALIZED = 0
    #   DB_NEEDS_UPGRADE = 1
    #   DB_IS_NEWER = 2
    #   DB_NEEDS_INIT = 3
    #   DB_VERSION_ERR = 4
    #   Negative return code indicates some type of execution error
    case $rc in
      0)
        echo "DB initialized and matches UCD server version"
        updateDbValues
        ;;
      1)
        echo "DB initialized, needs upgrade"
        initOrUpgradeUcdDb upgrade
        dbRC=$?
        if [ ${dbRC} -eq 0 ] ; then
            updateDbValues
            # When in an upgrade case, we need to remove certain persisted
            # files/dirs so they will be upgraded by docker-entrypoint.sh when
            # the main container executes.
            rm -rf ${APPDATA}/servers/shared/opt/air-agentupgrade.jar \
                   ${APPDATA}/servers/shared/opt/tomcat/webapps/ROOT/static \
                   ${APPDATA}/servers/shared/opt/tomcat/webapps/ROOT/WEB-INF/web.xml

            # Disable any patches
            disablePatches
        fi
        ;;
      2)
        echo "DB version is newer than UCD server version, exiting!"
        exit 1
        ;;
      3)
        echo "DB needs to be initialized"
        initOrUpgradeUcdDb init
        dbRC=$?
        if [ ${dbRC} -eq 0 ] ; then
            updateDbValues
        fi
        ;;
      *)
        echo "Error encountered while checking DB version"
        exit $rc
        ;;
    esac
else
        if [[ -n "${UCD_WEB_URL}" ]]; then
    if [ "${HOST_NAME:(-5)}" = "dfe-0" ] ; then
            echo "Updating External User URL to point to DFE proxy and node port"
            set +e
            java -cp "/usr/local/lib/UcdDbUtils.jar:${UCD_HOME}/lib/ext/*:${UCD_HOME}/lib/derbyclient.jar:${UCD_HOME}/lib/CommonsUtil.jar:${UCD_HOME}/lib/commons-codec.jar:${UCD_HOME}/lib/log4j.jar:${UCD_HOME}/lib/commons-lang3.jar:" UcdDbUtils setExternalUserURL ${UCD_WEB_URL} "${UCD_HOME}/" "${DB_TYPE}" "${DB_NAME}" "${DB_USER}" "${DB_PASSWORD}" "${DB_TCP_URL}" "${DB_TCP_PORT}" "${DB_JDBC_CONN_URL}"
            set -e
        else
            echo "updateDbValues: UCD_WEB_URL is not set, cannot set external user URL!!!"
        fi
    fi

    if [ "${ENABLE_HA}" == "Y" ]; then
        # ensure the jdbc jars are mounted and accessible
        if [ ! -d ${UCD_HOME}/lib/ext ]; then
            mkdir ${UCD_HOME}/lib/ext
        fi
        ls ${UCD_HOME}/ext_lib/*.jar
        if [ $? -eq 0 ] ; then
            cp ${UCD_HOME}/ext_lib/*.jar ${UCD_HOME}/lib/ext
        else
            echo "Persistent storage holding JDBC libraries was not found. Database connections will likely fail."
        fi
    else
        echo "High Availability mode not enabled in this image. Exiting!"
        exit 1
    fi
fi

#
# Setup appdata and other persisted files
#
if [ "${SECURE,,}" == "y" ] ; then
  if [[ -z "${UCD_WEB_URL}" ]] ; then
      export UCD_WEB_URL="https://${UCD_SERVER_NAME}:${UCD_SECURE_PORT}"
  fi
  cp /tmp/server-https.xml ${UCD_HOME}/opt/tomcat/conf/server.xml
else
  export SECURE="N"
  if [[ -z "${UCD_WEB_URL}" ]] ; then
      export UCD_WEB_URL="http://${UCD_SERVER_NAME}:${UCD_PORT}"
  fi
  cp /tmp/server.xml ${UCD_HOME}/opt/tomcat/conf/server.xml
  cp /tmp/web.xml ${UCD_HOME}/opt/tomcat/webapps/ROOT/WEB-INF/web.xml
fi

if [ ! -d ${APPDATA}/conf ] || [ -f ${APPDATA}/loadInProgress ] ; then
    if [ -f ${APPDATA}/loadInProgress ] ; then
        echo "Previous load of appdata-from-install did not complete.  You may need to increase the liveness probe timeout values."
    fi
    echo "Loading ${APPDATA} from UCD install"
    touch ${APPDATA}/loadInProgress
    if [ "${DB_TYPE}" = "derby" ] ; then
        # Derby database was created in init container, don't want to overwrite
        mv -f ${APPDATA}/var/db ${UCD_HOME}/appdata-from-install/var
    fi
    echo "APPDATA contains the following files/dirs before loading:"
    ls -lR ${APPDATA}
    mv -f ${UCD_HOME}/appdata-from-install/* ${APPDATA}
    rm -f ${APPDATA}/loadInProgress
fi
rm -rf ${UCD_HOME}/appdata-from-install

# Create unique keystore files if they don't already exist.  The original
# (non-unique) keystore files were removed from the image as part of the
# docker build process.
if [ ! -f ${APPDATA}/conf/encryption.keystore ] ; then
    createKeystoreFiles
fi

# Create symlinks in server install directory to persisted files/directories
if [ "${DB_TYPE}" != "derby" ] ; then  # Derby not currently persisted
    createSymLinks
fi

# Update keystore passwords if one was specified, only do this in the
# initial server instance
if [ -n "${UCD_KEYSTORE_PASSWORD}" ] ; then
    if [ "${HOST_NAME:(-6)}" = "prod-0" ] ; then
        # If current keystore password is still 'changeit', we need to update it
        # to be the value specified in the secret.
        # allow keytool to fail without exiting
        set +e
        keytool -list -storepass changeit -keystore ${APPDATA}/conf/encryption.keystore -storetype jceks > /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            echo "Updating keystore passwords"
            updateKeystorePasswords
        else
            # Keystore password is not 'changeit', verify it is UCD_KEYSTORE_PASSWORD
            keytool -list -storepass ${UCD_KEYSTORE_PASSWORD} -keystore ${APPDATA}/conf/encryption.keystore -storetype jceks > /dev/null 2>&1
            if [ $? -eq 0 ] ; then
                echo "Keystore passwords updated on previous initialization."
            else
                echo "Keystore passwords do not match value specified in secret!"
                exit 1
            fi
        fi
        set -e
    elif [[ "${HOST_NAME}" =~ .*"prod-"[0-9]+$ ]] ; then
        # If we are a server instance other than the first, we may need to
        # update the S2S keystore password only.
        set +e
        keytool -list -storepass changeit -keystore ${UCD_HOME}/conf/server/s2s-client-identity.keystore -storetype jceks > /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            echo "Updating S2S keystore password"
            updateS2SKeystorePassword
        fi
        set -e
   fi
fi

# If UCD_KEYSTORE_PASSWORD not set, don't add keystore related properites
# to secured_installed.properties
if [ -z "${UCD_KEYSTORE_PASSWORD}" ] ; then
    cat /tmp/secured-installed.properties.template | envsubst > /tmp/secured-installed.properties.updated
    STORE_PASSWORD="changeit"
else
    cat /tmp/secured-keystore-installed.properties.template /tmp/secured-installed.properties.template | envsubst > /tmp/secured-installed.properties.updated
    STORE_PASSWORD="${UCD_KEYSTORE_PASSWORD}"
fi

update_props_file /tmp/secured-installed.properties.updated ${UCD_HOME}/conf/server/secured-installed.properties

# Get count of aliases/keys in encryption.keystore.  If we only have one, then
# update installed.properties with that alias name.  If we have multiple
# aliases then leave installed.properties with the current value for
# encryption.keystore.alias.
set +e
keytool -list -v -storepass "${STORE_PASSWORD}" -keystore ${APPDATA}/conf/encryption.keystore -storetype jceks > /tmp/keystore-info
if [ $? -ne 0 ] ; then
    echo "Could not retrieve encryption.keystore info, cannot continue!!!"
    exit 1
fi
set -e
TEMPLATE_FILE=/tmp/installed.properties.template
ENCRYPTION_ALIAS_CNT=$(grep -i alias /tmp/keystore-info | wc -l)
if [ ${ENCRYPTION_ALIAS_CNT} -eq 1 ] ; then
    export ENCRYPTION_ALIAS=$(grep -i alias /tmp/keystore-info | awk '{print $3}')
else
    TEMPLATE_FILE=/tmp/installed.properties.template.noalias
    sed -e "/^encryption.keystore.alias.*/ d" /tmp/installed.properties.template > ${TEMPLATE_FILE}
fi
rm /tmp/keystore-info
envsubst < ${TEMPLATE_FILE} > /tmp/installed.properties.updated
update_props_file /tmp/installed.properties.updated ${UCD_HOME}/conf/server/installed.properties
if [ "${SECURE,,}" != "y" ] ; then
    sed -i -e "/^install.server.web.https.port.*/ d" ${UCD_HOME}/conf/server/installed.properties
fi

if [ "${DEBUG_ENABLED}" = "true" ] ; then
    echo "##### Contents of secured-installed.properties follows: ####"
    cat ${UCD_HOME}/conf/server/secured-installed.properties
    echo "##### Contents of installed.properties follows: ####"
    cat ${UCD_HOME}/conf/server/installed.properties
fi

PLUGINS_REPO=${UCD_HOME}/appdata/var/plugins/command/repo
PLUGINS_STAGE=${UCD_HOME}/appdata/var/plugins/command/stage

PLUGINS_LIST="kubernetes openshift"

if [ ! -d ${PLUGINS_REPO} ] ; then
    for plugin in $PLUGINS_LIST
    do
       cp /tmp/plugins/*${plugin}*.zip ${PLUGINS_STAGE}
    done
else
    ls ${PLUGINS_REPO} > /tmp/plugin-list
    for plugin in ${PLUGINS_LIST}
    do
        set +e
        grep ${plugin} /tmp/plugin-list > /dev/null 2>&1
        rc=$?
        set -e
        if [ ${rc} -ne 0 ] ; then
            echo "Installing ${plugin} plugin"
            cp /tmp/plugins/*${plugin}*.zip ${PLUGINS_STAGE}
        fi
    done
fi

# Handle possible upgrade from earlier containerized versions that used IBM JRE.
# Ensure that set_env is setting JAVA_HOME and JAVA_OPTS correctly for OpenJDK.
# Need to make sure we don't change any additions the user may have made.
# Only make changes if bin/set_env contains IBM Java options.
# sed -i will delete the original file thus breaking our symlink for set_env,
# so we don't use -i and copy the changes back instead.
set +e
grep Xdump ${UCD_HOME}/bin/set_env > /dev/null 2>&1
rc=$?
set -e
if [ ${rc} -eq 0 ] ; then
    sed -e "/^JAVA_HOME/ s'^JAVA_HOME=.*$'JAVA_HOME=${JAVA_HOME}'" -e '/^JAVA_OPTS/ s/-Xdump:[^ ][^ ]*//g' -e '/^JAVA_OPTS/ s/-Dcatalina.base/-XX:+HeapDumpOnOutOfMemoryError -Dcatalina.base/' ${UCD_HOME}/bin/set_env > /tmp/set_env
    cp /tmp/set_env ${UCD_HOME}/bin/set_env
fi

# Extract keytool rotation utilities to directory in appdata
unzip -qq -o /tmp/keytools-* -d ${UCD_HOME}/appdata

# Cleanup
rm -f /tmp/secured-installed.properties.updated /tmp/install*.noalias

# Successfully completed initialization
exit 0
