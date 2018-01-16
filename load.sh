#!/usr/bin/env bash

[ -z "$1" ] && exit 1

DUMPBASE="/docker-entrypoint-initdb.d/10-mysqldump"
MYSQLOPTS="--max_allowed_packet=64M --innodb_log_files_in_group=8 --innodb_log_file_size=20M"

# Recover the dump unless it has been recovered before
if [ ! -r $DUMPBASE.sql* ] ; then

    ORIGDUMP=$1
    DUMPFILE="$RECOVERY_AREA/$(basename $ORIGDUMP)"

    # Recover the dump file
    echo "$(date '+%m/%d %H:%M:%S'): Recovering dump file: $DUMPFILE"
    [ -r $DUMPFILE ] && rm $DUMPFILE
    cat <<EOF | socat -,ignoreeof $RECOVERY_SOCKET
    { \
        "client": "$HOSTNAME", \
        "path": "$ORIGDUMP" \
    }
EOF
    [ -r $DUMPFILE ] || exit 5

    # Creating the link below will make docker-entrypoint.sh import it.
    # docker-entrypoint.sh uses filename extension to determine file type.
    file -L $DUMPFILE | grep -qwi 'gzip' && EXT='sql.gz' || EXT='sql'
    ln -s $DUMPFILE "$DUMPBASE.$EXT"
    chown mysql:mysql $DUMPFILE

    recoverytestuser.sh
    coproc tailcop { exec docker-entrypoint.sh $MYSQLOPTS --skip-networking 2>&1 ; }

    sleep 10800 && echo "$(date '+%m/%d %H:%M:%S'): Timeout during init" && kill $tailcop_PID &

    while read -ru ${tailcop[0]} line; do
        echo $line
        [ $(expr "$line" : 'MySQL init process done. Ready for start up.') -gt 0 ] && break
    done

    while read -ru ${tailcop[0]} line; do
        echo $line
        [ $(expr "$line" : '.*\[Note\] mysqld: ready for connections.') -gt 0 ] && break
    done
    sleep 1
    # Init completed, kill the timeout killer
    pkill -x sleep
    echo "$(date '+%m/%d %H:%M:%S'): Shutting down MySQL Server"
    kill $tailcop_PID
    # Wait for shutdown while showing progress
    cat <&${tailcop[0]}
else
    # Delegate control to docker-entrypoint.sh
    exec /usr/local/bin/docker-entrypoint.sh $MYSQLOPTS 
fi
