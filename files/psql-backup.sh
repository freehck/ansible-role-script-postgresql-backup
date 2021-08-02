#!/bin/bash

# strict mode
set -euo pipefail

# script specific vars
PROGNAME=$(basename "$0")
VERSION=1.0.2

# defaults
: ${HOST:=$(hostname)}
: ${TMPDIR:="/tmp"}
: ${DEBUG:="no"}
: ${BKP_PREFIX:="backup"}
: ${BKP_TSTAMP_FORMAT:="%F-%Hh%Mm%Ss"}

: ${BKP_WARN_SIZE:=0}
: ${BKP_GZIP:=no}
: ${BKP_ENCRYPT_AES:=no}
: ${BKP_ENCRYPT_AES_KEY:=""}

: ${PSQL_HOST:="127.0.0.1"}
: ${PSQL_PORT:=5432}
: ${PSQL_USER:=postgres}
: ${PSQL_PASS:=""}
: ${PSQL_DB:=""}

: ${S3_CFG:=""}
: ${S3_BUCKET:=""}
: ${S3_STORAGE:=no}

: ${SCP_HOST:=""}
: ${SCP_USER:="$USER"}
: ${SCP_DST:=""}
: ${SCP_IDENTITY:=""}
: ${SCP_STORAGE:=no}

: ${LOCAL_STORAGE:=no}
: ${LOCAL_DST:=""}
: ${SLACK_WH_URL:=""}

# tools
: ${PGDUMP:=/usr/bin/pg_dump}
: ${CURL:=/usr/bin/curl}
: ${S3CMD:=/usr/bin/s3cmd}
: ${SSH:=/usr/bin/ssh}
: ${SCP:=/usr/bin/scp}
: ${OPENSSL:=/usr/bin/openssl}

# base functions
msg() {
    echo "$@"
}

err() {
    >&2 echo "$@"
}

errcat() {
    >&2 cat
}

print_help() {
    cat <<EOF
$PROGNAME [options]

Description: make backup of psql database and store it somewhere
Version: $VERSION

Options:
--tmpdir                        specify tmpdir to store files temprary (default: "$TMPDIR")
--bkp-prefix str                prefix of backup file (default: "$BKP_PREFIX")
--bkp-tstamp-format str         format of timestamp that is put in the end of backup file name (default: "$BKP_TSTAMP_FORMAT")
--bkp-warn-size num             size in GiB to suspect something bad if backup size is less (default: "$BKP_WARN_SIZE")
--psql-host addr                specify addr of psql server to connect (default: "$PSQL_HOST")
--psql-port port                specify port of psql server to connect (default: "$PSQL_PORT")
--psql-user str         specify psql username (default: "$PSQL_USER")
--psql-pass str         specify psql password (default: "$PSQL_PASS")
--psql-db str                   specify psql database (default: "$PSQL_DB")
--s3-cfg path                   specify configuration file for s3cmd tool (default: "$S3_CFG")
--s3-bucket str                 specify S3 bucket to store backup (default: "$S3_BUCKET")
--scp-host str                  specify host to scp your backup (default: "$SCP_HOST")
--scp-dst str                   specify destination path to scp your backup (default: "$SCP_DST")
--local-dst str                 specify destination path to scp your backup (default: "$LOCAL_DST")
--slack-webhook url             specify url to send slack notifications (default: "$SLACK_WH_URL")


These options are mandatory:
--psql-host
--psql-db

These options are recommended:
--tmpdir
--slack-webhook

All the flags can be omited if you use appropriate environment variables.
Look at the sources if you want to use them.

EOF
}

parse_opts() {
    # modify cmdline
    local TEMP PARSE_OPTS_STATUS
    TEMP=$(getopt -o h --long help,debug,dbg,tmpdir:,bkp-prefix:,bkp-tstamp-format:,bkp-warn-size:,psql-host:,psql-user:,psql-pass:,psql-db:,s3-cfg:,s3-bucket:,scp-host:,scp-dst:,slack-webhook:,gzip,aes-key:,s3,scp,--scp-key: -- "$@")
    PARSE_OPTS_STATUS="$?"
    if [ "$PARSE_OPTS_STATUS" != 0 ]; then
        err "Error in parsing options";
        exit 1
    fi
    eval set -- "$TEMP"
    unset TEMP

    # parse cmdline options
    while true; do
        case "$1" in
            -h|--help) print_help; exit 0;;
            --debug|--dbg) DEBUG="yes"; shift;;
            --tmpdir) TMPDIR="$2"; shift 2;;
            --bkp-prefix) BKP_PREFIX="$2"; shift 2;;
            --bkp-tstamp-format) BKP_TSTAMP_FORMAT="$2"; shift 2;;
            --bkp-warn-size) BKP_WARN_SIZE="$2"; shift 2;;
            --psql-host) PSQL_HOST="$2"; shift 2;;
            --psql-port) PSQL_PORT="$2"; shift 2;;
            --psql-authdb) PSQL_AUTHDB="$2"; shift 2;;
            --psql-user) PSQL_USER="$2"; shift 2;;
            --psql-pass) PSQL_PASS="$2"; shift 2;;
            --s3) S3_STORAGE="yes"; shift;;
            --s3-cfg) S3_STORAGE="yes"; S3_CFG="$2"; shift 2;;
            --s3-bucket) S3_STORAGE="yes"; S3_BUCKET="$2"; shift 2;;
            --scp) SCP_STORAGE="yes"; shift 2;;
            --scp-host) SCP_STORAGE="yes"; SCP_HOST="$2"; shift 2;;
            --scp-user) SCP_STORAGE="yes"; SCP_USER="$2"; shift 2;;
            --scp-dst) SCP_STORAGE="yes"; SCP_DST="$2"; shift 2;;
            --local-dst) LOCAL_STORAGE="yes"; LOCAL_DST="$2"; shift 2;;
            --scp-key) SCP_STORAGE="yes"; SCP_IDENTITY="$2"; shift 2;;
            --slack-webhook) SLACK_WH_URL="$2"; shift 2;;
            --gzip) BKP_GZIP="yes"; shift;;
            --aes-key) BKP_ENCRYPT_AES="yes"; BKP_ENCRYPT_AES_KEY="$2"; shift 2;;
            --) shift; break;;
            *) err "Unknown option $1"; exit 2;;
        esac
    done
}

print_conf() {
    errcat <<EOF
---------- Configuration ----------
PROGNAME=$PROGNAME
VERSION=$VERSION
TMPDIR=$TMPDIR
------------- Psql ---------------
PSQL_HOST=$PSQL_HOST
PSQL_PORT=$PSQL_PORT
PSQL_DB=$PSQL_DB
PSQL_USER=$PSQL_USER
PSQL_PASS=$PSQL_PASS
EOF
    if [ "$S3_STORAGE" = "yes" ]; then
        errcat <<EOF
----------- S3 Storage ------------
S3_CFG=$S3_CFG
S3_BUCKET=$S3_BUCKET
EOF
    fi
    if [ "$SCP_STORAGE" = "yes" ]; then
        errcat <<EOF
----------- SCP Storage -----------
SCP_HOST=$SCP_HOST
SCP_USER=$SCP_USER
SCP_DST=$SCP_DST
SCP_IDENTITY=$SCP_IDENTITY
EOF
    fi
    if [ "$LOCAL_STORAGE" = "yes" ]; then
        errcat <<EOF
----------- LOCAL Storage -----------
LOCAL_DST=$LOCAL_DST
EOF
    fi
    if [ -n "$SLACK_WH_URL" ]; then
        errcat <<EOF
---------- Integration -----------
SLACK_WH_URL=$SLACK_WH_URL
EOF
    fi
    errcat <<EOF
-------- Special Abilities -------
EOF
    if [ "$BKP_GZIP" = "yes" ]; then
        errcat <<EOF
BKP_GZIP=$BKP_GZIP
EOF
    fi
    if [ "$BKP_ENCRYPT_AES" = "yes" ]; then
        errcat <<EOF
BKP_ENCRYPT_AES=$BKP_ENCRYPT_AES
BKP_ENCRYPT_AES_KEY=$BKP_ENCRYPT_AES_KEY
EOF
    fi
    errcat <<EOF
-----------------------------------
EOF
}

check_conf() {
    local found_conf_errors="no"

    # at least one storage exist
    if [ "$S3_STORAGE" = "no" ] && [ "$SCP_STORAGE" = "no" ] && [ "$LOCAL_STORAGE" = "no" ]; then
        found_conf_errors="yes"
        errcat <<EOF
You must specify at least one backend to store backups. Check --local-dst, --s3 or --scp options.
EOF
    fi

    # s3 storage
    if [ "$S3_STORAGE" = "yes" ]; then
        if [ -z "$S3_BUCKET" ]; then
            found_conf_errors="yes"
            errcat <<EOF
When you use s3 storage, you shall specify s3 bucket. Check --s3-bucket option.
EOF
        fi
        if [ -z "$S3_CFG" ]; then
            found_conf_errors="yes"
            errcat <<EOF
When you use s3 storage, you shall specify path to the s3cfg file. Check --s3-cfg option.
EOF
        fi
        if [ ! -f "$S3_CFG" ]; then
            found_conf_errors="yes"
            errcat <<EOF
S3 configuration file not found: $S3_CFG
EOF
        fi
    fi
    
    # scp storage
    if [ "$SCP_STORAGE" = "yes" ]; then
        if [ -z "$SCP_HOST" ]; then
            found_conf_errors="yes"
            errcat <<EOF
When you use scp storage, you shall specify host. Check --scp-host option.
EOF
        fi
        if [ -z "$SCP_DST" ]; then
            found_conf_errors="yes"
            errcat <<EOF
When you use scp storage, you shall specify storage host destination dir. Check --scp-dst option.
EOF
        fi
        if [ -z "$SCP_IDENTITY" ]; then
            found_conf_errors="yes"
            errcat <<EOF
When you use scp storage, you shall specify identity key file. Check --scp-key option.
EOF
        fi
    fi

    # local storagew
    if [ "$LOCAL_STORAGE" = "yes" ]; then
        if [ -z "$LOCAL_DST" ]; then
            found_conf_errors="yes"
            errcat <<EOF
When you use local storage, you shall specify storage destination dir. Check --local-dst option.
EOF
        fi
    fi
    # tstamp format
    if ! date +"$BKP_TSTAMP_FORMAT" &>/dev/null; then
        found_conf_errors="yes"
        errcat <<EOF
Invalid time format: "$BKP_TSTAMP_FORMAT". Check --bkp-tstamp-format option.
EOF
    fi

    # aes key file
    if [ "$BKP_ENCRYPT_AES" = "yes" ] && [ ! -f "$BKP_ENCRYPT_AES_KEY" ]; then
        found_conf_errors="yes"
        errcat <<EOF
AES Key not found: $BKP_ENCRYPT_AES_KEY. Check --aes-key option.
EOF
    fi

    # --- stop if errors found ---
    if [ "$found_conf_errors" = "yes" ]; then
        exit 3
    fi
}

slack() {
    if [ -n "$SLACK_WH_URL" ]; then
        text="$@"
        set +e
        $CURL -s -X POST -H 'Content-type: application/json' \
              --data '{"text":"'"[$HOST] $text"'"}' \
              https://hooks.slack.com/services/$SLACK_WH_URL \
              &>/dev/null
        set -e
    fi
}




# PROGRAM BEGIN

parse_opts "$@"
if [ "$DEBUG" = "yes" ]; then print_conf; fi
check_conf

tstamp=$(date +"$BKP_TSTAMP_FORMAT")
bkpd=$(mktemp -p "$TMPDIR" -d psql-backup-tempdir.XXXXXXXX)
trap "rm -rf $bkpd;" err int exit
(
  cd "$bkpd"
  trap "msg fail; slack 'ERROR HAPPENED, CHECK BACKUPS IMMEDIATELY'" err
  slack "Start psql backup"
  msg "Start psql backup: $(date +%F-%T)"

  bkp="$BKP_PREFIX-$tstamp.sql"
  
  if [ "$BKP_GZIP" = "yes" ]; then
      msg -n "Dump database and gzip it... "
      bkp="$bkp.gz"
      $PGDUMP --dbname=postgresql://${PSQL_USER}:${PSQL_PASS}@${PSQL_HOST}:${PSQL_PORT}/${PSQL_DB} | gzip -c > $bkp
  else
      msg -n "Dump database... "
      $PGDUMP --dbname=postgresql://${PSQL_USER}:${PSQL_PASS}@${PSQL_HOST}:${PSQL_PORT}/${PSQL_DB} > $bkp
  fi
  msg ok

  if [ "$BKP_ENCRYPT_AES" = "yes" ]; then
      msg -n "Encrypt dump with aes256 algorithm... "
      $OPENSSL enc -aes-256-cbc -salt -pass "file:$BKP_ENCRYPT_AES_KEY" -in "$bkp" -out "$bkp.enc"
      rm -f "$bkp"
      bkp="$bkp.enc"
      msg ok
  fi

  if [ "$S3_STORAGE" = "yes" ]; then
      msg -n "Copy backup file to S3 storage... "
      $S3CMD -c "$S3_CFG" put "$bkp" "s3://$S3_BUCKET" &>/dev/null
      msg ok
  fi

  if [ "$SCP_STORAGE" = "yes" ]; then
      msg -n "Copy backup file via SSH to $SCP_HOST..."
      $SSH -i "$SCP_IDENTITY" $SCP_USER@$SCP_HOST mkdir -p $SCP_DST
      $SCP -i "$SCP_IDENTITY" $bkp $SCP_USER@$SCP_HOST:$SCP_DST/$bkp >/dev/null
      msg ok
  fi

    if [ "$LOCAL_STORAGE" = "yes" ]; then
      msg -n "Copy backup file to dir at local storage..."
      mkdir -p $LOCAL_DST
      cp $bkp $LOCAL_DST/$bkp >/dev/null
      msg ok
  fi

  msg -n "Check if backup size is fine... "
  bkp_size=$(stat --printf="%s" "$bkp")
  if [ "$bkp_size" -gt $((BKP_WARN_SIZE*2**20)) ]; then
      msg ok
  else
      msg fail
      msg "Size of backup is less than $BKP_WARN_SIZE MiB. Suspicious."
      slack "WARNING: Size of backup is less than $BKP_WARN_SIZE GiB. Suspicious.\nBackup name: $bkp"
  fi

  msg "Backup complete: $(date +%F-%T)"
  slack "Backup complete. File: s3://$S3_BUCKET/$bkp ($((bkp_size / 2**20)) MiB)"
)
