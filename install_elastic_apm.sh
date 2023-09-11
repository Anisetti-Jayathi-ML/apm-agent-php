#!/usr/bin/env bash

if [ `which yum` ]; then
   IS_RHEL=1
elif [ `which apt` ]; then
   IS_UBUNTU=1
elif [ `which apk` ]; then
   IS_ALPINE=1
else
   IS_UNKNOWN=1
fi

if [  $IS_UBUNTU == 1 ]; then
    echo "Ubuntu found"
    apt install build-essential libcurl4-openssl-dev jq git -y
elif [ $IS_RHEL == 1 ]; then
    echo "centos found"
    yum install libcurl-devel jq git -y && yum group install "Development Tools"
fi

rm -rf /opt/elasticapm/phpagent

git clone --branch 4.x --single-branch https://github.com/snappyflow/apm-agent-php.git --depth 1 /opt/elasticapm/phpagent

cd /opt/elasticapm/phpagent

ELASTIC_SERVICE_NAME=$1
PHP_AGENT_DIR=$(pwd)
EXTENSION_DIR="${PHP_AGENT_DIR}/extensions"
EXTENSION_CFG_DIR="${PHP_AGENT_DIR}/etc"
BOOTSTRAP_FILE_PATH="${PHP_AGENT_DIR}/agent/php/bootstrap_php_part.php"
BACKUP_EXTENSION=".agent.bck"
ELASTIC_INI_FILE_NAME="elastic-apm.ini"
CUSTOM_INI_FILE_NAME="elastic-apm-custom.ini"

rm -rf ${EXTENSION_CFG_DIR}
rm -rf ${EXTENSION_DIR}

mkdir -p ${EXTENSION_CFG_DIR}
mkdir -p ${EXTENSION_DIR}
# mkdir -p "${PHP_AGENT_DIR}/src"

cd agent/native/ext
phpize
CFLAGS="-std=gnu99" ./configure --enable-elastic_apm
make clean
make
# sudo make install

cd ../../..

cp -rf agent/native/ext/modules/* ${EXTENSION_DIR}

touch ${EXTENSION_CFG_DIR}/elastic-apm.ini


#### Function php_command ######################################################
function php_command() {
    PHP_BIN=$(command -v php)
    ${PHP_BIN} -d memory_limit=128M "$@"
}

#### Function php_ini_file_path ################################################
function php_ini_file_path() {
    php_command -i \
        | grep 'Configuration File (php.ini) Path =>' \
        | sed -e 's#Configuration File (php.ini) Path =>##g' \
        | head -n 1 \
        | awk '{print $1}'
}

#### Function php_api ##########################################################
function php_api() {
    php_command -i \
        | grep 'PHP API' \
        | sed -e 's#.* =>##g' \
        | awk '{print $1}'
}


#### Function php_config_d_path ################################################
function php_config_d_path() {
    php_command -i \
        | grep 'Scan this dir for additional .ini files =>' \
        | sed -e 's#Scan this dir for additional .ini files =>##g' \
        | head -n 1 \
        | awk '{print $1}'
}

################################################################################
#### Function is_extension_enabled #############################################
function is_extension_enabled() {
    php_command -m | grep -q 'elastic'
}

################################################################################
#### Function install_conf_d_files #############################################
function install_conf_d_files() {
    PHP_CONFIG_D_PATH=$1
    INI_FILE_PATH="${EXTENSION_CFG_DIR}/$ELASTIC_INI_FILE_NAME"
    CUSTOM_INI_FILE_PATH="${EXTENSION_CFG_DIR}/${CUSTOM_INI_FILE_NAME}"

    generate_configuration_files "${INI_FILE_PATH}" "${CUSTOM_INI_FILE_PATH}"

    echo "Configuring ${ELASTIC_INI_FILE_NAME} for supported SAPI's"

    # Detect installed SAPI's
    SAPI_DIR=${PHP_CONFIG_D_PATH%/*/conf.d}/
    SAPI_CONFIG_DIRS=()
    if [ "${PHP_CONFIG_D_PATH}" != "${SAPI_DIR}" ]; then
        # CLI
        CLI_CONF_D_PATH="${SAPI_DIR}cli/conf.d"
        if [ -d "${CLI_CONF_D_PATH}" ]; then
            SAPI_CONFIG_DIRS+=("${CLI_CONF_D_PATH}")
        fi
        # Apache
        APACHE_CONF_D_PATH="${SAPI_DIR}apache2/conf.d"
        if [ -d "${APACHE_CONF_D_PATH}" ]; then
            SAPI_CONFIG_DIRS+=("${APACHE_CONF_D_PATH}")
        fi
        ## FPM
        FPM_CONF_D_PATH="${SAPI_DIR}fpm/conf.d"
        if [ -d "${FPM_CONF_D_PATH}" ]; then
            SAPI_CONFIG_DIRS+=("${FPM_CONF_D_PATH}")
        fi
    fi

    if [ ${#SAPI_CONFIG_DIRS[@]} -eq 0 ]; then
        SAPI_CONFIG_DIRS+=("$PHP_CONFIG_D_PATH")
    fi

    for SAPI_CONFIG_D_PATH in "${SAPI_CONFIG_DIRS[@]}" ; do
        echo "Found SAPI config directory: ${SAPI_CONFIG_D_PATH}"
        link_file "${INI_FILE_PATH}" "${SAPI_CONFIG_D_PATH}/98-${ELASTIC_INI_FILE_NAME}"
        link_file "${CUSTOM_INI_FILE_PATH}" "${SAPI_CONFIG_D_PATH}/99-${CUSTOM_INI_FILE_NAME}"
    done
}

################################################################################
#### Function generate_configuration_files #####################################
function generate_configuration_files() {
    INI_FILE_PATH="${1}"
    CUSTOM_INI_FILE_PATH="${2}"

    ## IMPORTANT: This file will be always override if already exists for a
    ##            previous installation.
    echo "Creating ${INI_FILE_PATH}"
    CONTENT=$(add_extension_configuration)
    tee "${INI_FILE_PATH}" <<EOF
; ***** DO NOT EDIT THIS FILE *****
; THIS IS AN AUTO-GENERATED FILE by the Elastic PHP agent post-install.sh script
; To overwrite the INI settings for this extension, edit
; the INI file in this directory "${CUSTOM_INI_FILE_PATH}"
[elastic]
${CONTENT}
; END OF AUTO-GENERATED by the Elastic PHP agent post-install.sh script
EOF

    echo "${INI_FILE_PATH} created"

    if [ ! -f "${CUSTOM_INI_FILE_PATH}" ]; then
        # touch "${CUSTOM_INI_FILE_PATH}"
        # Post installation
        server_url=`/opt/sfagent/sftrace/sftrace | jq ".SFTRACE_SERVER_URL"`
        global_labels=`/opt/sfagent/sftrace/sftrace | jq ".SFTRACE_GLOBAL_LABELS"`
        verify_cert=`/opt/sfagent/sftrace/sftrace | jq ".SFTRACE_VERIFY_SERVER_CERT"`

cat <<EOF >${CUSTOM_INI_FILE_PATH}
[elastic]
elastic_apm.enabled = true
elastic_apm.environment = "production"
elastic_apm.server_timeout = "30s"
elastic_apm.server_url = $server_url
elastic_apm.service_name = "${ELASTIC_SERVICE_NAME}"
elastic_apm.verify_server_cert = $verify_cert
elastic_apm.global_labels = $global_labels
EOF
        echo "Created empty ${CUSTOM_INI_FILE_PATH}"
    fi
}

################################################################################
#### Function link_file ########################################################
function link_file() {
    echo "Linking ${1} to ${2}"
    test -f "${2}" && rm "${2}"
    ln -s "${1}" "${2}"
}

################################################################################
#### Function add_extension_configuration_to_file ##############################
function add_extension_configuration_to_file() {
    CONTENT=$(add_extension_configuration)
    ## IMPORTANT: The below content is also used in the before-uninstall.sh
    ##            script.
    tee -a "$1" <<EOF
; THIS IS AN AUTO-GENERATED FILE by the Elastic PHP agent post-install.sh script
${CONTENT}
; END OF AUTO-GENERATED by the Elastic PHP agent post-install.sh script
EOF
}

################################################################################
#### Function add_extension_configuration ######################################
function add_extension_configuration() {
    cat <<EOF
extension=${EXTENSION_FILE_PATH}
elastic_apm.bootstrap_php_part_file=${BOOTSTRAP_FILE_PATH}
EOF
}

################################################################################
#### Function get_extension_file ###############################################
function get_extension_file() {
    # PHP_API=$(php_api)
    echo "${EXTENSION_DIR}/elastic_apm.so"
}


################################################################################
#### Function is_php_supported #################################################
function is_php_supported() {
    PHP_MAJOR_MINOR=$(php_command -r 'echo PHP_MAJOR_VERSION;').$(php_command -r 'echo PHP_MINOR_VERSION;')
    echo "Detected PHP version '${PHP_MAJOR_MINOR}'"
    sup_vers=("7.2" "7.3" "7.4" "8.0" "8.1" "8.2")
    for sv in "${sup_vers[@]}"; do
       if [[ "$sv" == "${PHP_MAJOR_MINOR}" ]]; then
          return 0
       fi
    done
    echo "Failed. The supported PHP versions are ${sup_vers[@]}"
    return 1
}


############################### MAIN ###########################################
################################################################################
echo 'Installing Elastic PHP agent'
EXTENSION_FILE_PATH=$(get_extension_file)
PHP_INI_FILE_PATH="$(php_ini_file_path)/php.ini"
PHP_CONFIG_D_PATH="$(php_config_d_path)"


echo "DEBUG: after-install parameter is '$1'"

if ! is_php_supported ; then
    echo 'Failed. Elastic PHP agent extension is not supported for the existing PHP installation.'
    exit 1
fi

if [ -e "${PHP_CONFIG_D_PATH}" ]; then
    install_conf_d_files "${PHP_CONFIG_D_PATH}"
else
    if [ -e "${PHP_INI_FILE_PATH}" ] ; then
        if [ -e "${EXTENSION_FILE_PATH}" ] ; then
            if grep -q "${EXTENSION_FILE_PATH}" "${PHP_INI_FILE_PATH}" ; then
                echo '  extension configuration already exists for the Elastic PHP agent.'
                echo '  skipping ... '
            else
                echo "${PHP_INI_FILE_PATH} has been configured with the Elastic PHP agent setup."
                cp -fa "${PHP_INI_FILE_PATH}" "${PHP_INI_FILE_PATH}${BACKUP_EXTENSION}"
                add_extension_configuration_to_file "${PHP_INI_FILE_PATH}"
            fi
        else
            agent_extension_not_supported
        fi
    else
        if [ -e "${EXTENSION_FILE_PATH}" ] ; then
            echo "${PHP_INI_FILE_PATH} has been created with the Elastic PHP agent setup."
            add_extension_configuration_to_file "${PHP_INI_FILE_PATH}"
        else
            agent_extension_not_supported
        fi
    fi
fi

if is_extension_enabled ; then
    echo 'Extension enabled successfully for Elastic PHP agent'
else
    echo 'Failed. Elastic PHP agent extension is not enabled'
    if [ -e "${PHP_INI_FILE_PATH}${BACKUP_EXTENSION}" ] ; then
        echo "Reverted changes in the file ${PHP_INI_FILE_PATH}"
        mv -f "${PHP_INI_FILE_PATH}${BACKUP_EXTENSION}" "${PHP_INI_FILE_PATH}"
    fi
    # manual_extension_agent_setup
fi


