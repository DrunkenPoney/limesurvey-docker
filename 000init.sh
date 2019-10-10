#!/bin/bash
set -eu
shopt -s extglob globstar dotglob

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both ${var} and ${fileVar} are set (but are exclusive)"
		exit 1
	fi
	local val="${def}"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "${var}"="${val}"
	unset "${fileVar}"
}

cd "${WEB_DOCUMENT_ROOT}"

if [ ! -f ".RELEASE_${LIMESURVEY_GIT_RELEASE}" ]; then
    compgen -G ".RELEASE_*" && rm .RELEASE_*

    echo >&2 "Retrieving LimeSurvey... "
    curl -sSL "https://github.com/LimeSurvey/LimeSurvey/archive/${LIMESURVEY_GIT_RELEASE}.tar.gz" -o "/tmp/lime.tar.gz"

    echo >&2 'Extracting files from archive...'
    tar -xzf /tmp/lime.tar.gz \
        --group=application \
        --owner=application \
        --strip-components=1 \
        --keep-newer-files \
        --exclude-vcs \
        --to-command="sh -c $(printf '%q' 'mkdir -p $(dirname "./$TAR_FILENAME") && touch "./$TAR_FILENAME" && dd of="./$TAR_FILENAME" >/dev/null 2>&1 && echo "./$TAR_FILENAME" ')" | \
        xargs -I {} touch -t 195001010000 {}
    
    rm /tmp/lime.tar.gz

    touch ".RELEASE_${LIMESURVEY_GIT_RELEASE}"
fi

file_env 'LIMESURVEY_DB_TYPE' 'mysql'
file_env 'LIMESURVEY_DB_HOST' 'mysql'
file_env 'LIMESURVEY_DB_PORT' '3306'
file_env 'LIMESURVEY_TABLE_PREFIX' ''
file_env 'LIMESURVEY_ADMIN_NAME' 'Lime Administrator'
file_env 'LIMESURVEY_ADMIN_EMAIL' 'lime@lime.lime'
file_env 'LIMESURVEY_ADMIN_USER' ''
file_env 'LIMESURVEY_ADMIN_PASSWORD' ''
file_env 'LIMESURVEY_DEBUG' '0'
file_env 'LIMESURVEY_SQL_DEBUG' '0'
file_env 'MYSQL_SSL_CA' ''
file_env 'LIMESURVEY_USE_INNODB' ''

# if we're linked to MySQL and thus have credentials already, let's use them
file_env 'LIMESURVEY_DB_NAME' "${MYSQL_ENV_MYSQL_DATABASE:-limesurvey}"
file_env 'LIMESURVEY_DB_USER' "${MYSQL_ENV_MYSQL_USER:-root}"

if [ "${LIMESURVEY_DB_USER}" = 'root' ]; then
    file_env 'LIMESURVEY_DB_PASSWORD' "${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}"
else
    file_env 'LIMESURVEY_DB_PASSWORD' "${MYSQL_ENV_MYSQL_PASSWORD:-}"
fi

if [ -z "${LIMESURVEY_DB_PASSWORD}" ]; then
    echo >&2 'error: missing required LIMESURVEY_DB_PASSWORD environment variable'
    echo >&2 '  Did you forget to -e LIMESURVEY_DB_PASSWORD=... ?'
    echo >&2
    echo >&2 '  (Also of interest might be LIMESURVEY_DB_USER and LIMESURVEY_DB_NAME.)'
    exit 1
fi

declare -A CONNECTION_STRINGS=(
    [mysql]="mysql:host=${LIMESURVEY_DB_HOST};port=${LIMESURVEY_DB_PORT};dbname=${LIMESURVEY_DB_NAME};"
    [dblib]="dblib:host=${LIMESURVEY_DB_HOST};dbname=${LIMESURVEY_DB_NAME}"
    [pgsql]="pgsql:host=${LIMESURVEY_DB_HOST};port=${LIMESURVEY_DB_PORT};user=${LIMESURVEY_DB_USER};password=${LIMESURVEY_DB_PASSWORD};dbname=${LIMESURVEY_DB_NAME};"
    [sqlsrv]="sqlsrv:Server=${LIMESURVEY_DB_HOST};Database=${LIMESURVEY_DB_NAME}"
)

if [ -z ${CONNECTION_STRINGS[${LIMESURVEY_DB_TYPE}]} ]; then
    echo >&2 "error: invalid database type: ${LIMESURVEY_DB_TYPE}"
    echo >&2 "  LIMESURVEY_DB_TYPE must be either \"mysql\", \"dblib\", \"pgsql\" or \"sqlsrv\"."
    exit 1
fi

if ! [ -e application/config/config.php ]; then
    echo >&2 "No config file in $(pwd) Copying default config file..."
    #Copy default config file but also allow for the addition of attributes
    echo "'attributes' => array()," | awk '/lime_/ && c == 0 { c = 1; system("cat") } { print }' application/config/config-sample-mysql.php > application/config/config.php
fi

# Install BaltimoreCyberTrustRoot.crt.pem
if [ ! -e BaltimoreCyberTrustRoot.crt.pem ]; then
    echo "Downloading BaltimoreCyberTrustroot.crt.pem"
    curl -o BaltimoreCyberTrustRoot.crt.pem -fsL "https://www.digicert.com/CACerts/BaltimoreCyberTrustRoot.crt.pem"
fi

# see http://stackoverflow.com/a/2705678/433558
sed_escape_lhs() {
    echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
}
sed_escape_rhs() {
    echo "$@" | sed -e 's/[\/&]/\\&/g'
}
php_escape() {
    php -r 'var_export(('$2') $argv[1]);' -- "$1"
}
set_config() {
    key="$1"
    value="$2"
    sed -i "/'$key'/s/>\(.*\)/>$value,/1"  application/config/config.php
}

set_config 'connectionString' "'${CONNECTION_STRINGS[${LIMESURVEY_DB_TYPE}]}'"
set_config 'tablePrefix' "'${LIMESURVEY_TABLE_PREFIX}'"
set_config 'username' "'${LIMESURVEY_DB_USER}'"
set_config 'password' "'${LIMESURVEY_DB_PASSWORD}'"
set_config 'urlFormat' "'path'"
set_config 'debug' "${LIMESURVEY_DEBUG}"
set_config 'debugsql' "${LIMESURVEY_SQL_DEBUG}"

if [ -n "${MYSQL_SSL_CA}" ]; then
    set_config 'attributes' "array(PDO::MYSQL_ATTR_SSL_CA => '\/var\/www\/html\/${MYSQL_SSL_CA}', PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT => false)"
fi

if [ -n "${LIMESURVEY_USE_INNODB}" ]; then
    #If you want to use INNODB - remove MyISAM specification from LimeSurvey code
    sed -i "/ENGINE=MyISAM/s/\(ENGINE=MyISAM \)//1" application/core/db/MysqlSchema.php
fi

chown application:application -R tmp 
mkdir -p upload/surveys
chown application:application -R upload 
chown application:application -R application/config

echo "Waiting for database..."
while ! curl -sL "${LIMESURVEY_DB_HOST}:${LIMESURVEY_DB_PORT:-3306}" 2>/dev/null; do sleep 1; done

DBSTATUS=$(TERM=dumb php -- "${LIMESURVEY_DB_HOST}" "${LIMESURVEY_DB_USER}" "${LIMESURVEY_DB_PASSWORD}" "${LIMESURVEY_DB_NAME}" "${LIMESURVEY_TABLE_PREFIX}" "${MYSQL_SSL_CA}" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

error_reporting(E_ERROR | E_PARSE);

$stderr = fopen('php://stderr', 'w');

list($host, $socket) = explode(':', $argv[1], 2);
$port = 0;
if (is_numeric($socket)) {
        $port = (int) $socket;
        $socket = null;
}

$maxTries = 10;
do {
    $con = mysqli_init();
    if (isset($argv[6]) && !empty($argv[6])) {
        mysqli_ssl_set($con,NULL,NULL,"/var/www/html/" . $argv[6],NULL,NULL);
    }
    $mysql = mysqli_real_connect($con,$host, $argv[2], $argv[3], '', $port, $socket, MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT);
        if (!$mysql) {
                fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
                --$maxTries;
                if ($maxTries <= 0) {
                        exit(1);
                }
                sleep(3);
        }
} while (!$mysql);

if (!$con->query('CREATE DATABASE IF NOT EXISTS `' . $con->real_escape_string($argv[4]) . '`')) {
        fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $con->error . "\n");
        $con->close();
        exit(1);
}

$con->select_db($con->real_escape_string($argv[4]));

$inst = $con->query("SELECT * FROM `" . $con->real_escape_string($argv[5]) . "users" . "`");

$con->close();

if ($inst->num_rows > 0) {
        exit("DBEXISTS");
} else {
        exit(0);
}

EOPHP
) &>/dev/null

# cd application/commands/
if [ "${DBSTATUS}" != "DBEXISTS" ] &&  [ -n "${LIMESURVEY_ADMIN_USER}" ] && [ -n "${LIMESURVEY_ADMIN_PASSWORD}" ]; then
    echo >&2 'Database not yet populated - installing Limesurvey database'
    su - application -c php ./application/commands/console.php install "${LIMESURVEY_ADMIN_USER}" "${LIMESURVEY_ADMIN_PASSWORD}" "${LIMESURVEY_ADMIN_NAME}" "${LIMESURVEY_ADMIN_EMAIL}" verbose
fi

if [ -f './application/commands/UpdateDbCommand.php' ]; then
    echo >&2 'Updating database'
    su - application -c php ./application/commands/console.php updatedb
else
    echo >&2 'WARNING: Manual database update may be required!'
fi

if [ -n "${LIMESURVEY_ADMIN_USER}" ] && [ -n "${LIMESURVEY_ADMIN_PASSWORD}" ]; then
    echo >&2 'Updating password for admin user'
    su - application -c php ./application/commands/console.php resetpassword "${LIMESURVEY_ADMIN_USER}" "${LIMESURVEY_ADMIN_PASSWORD}"
fi

