#!/usr/bin/env bash
[ -z "$1" ] && exit 1

if [ ! -d "/var/lib/mysql/mysql" ]; then

    SnapShotDir=$1
    BinLogDir=${2:-$(dirname $SnapShotDir)/binlog}
    Time=${3:-null}
    RecoveryDir="$RecoveryArea/$(basename $SnapShotDir)"
    DataDir="$RecoveryDir/dbs"
    Report="$RecoveryArea/recovery_report.txt"
    [ -e $Report ] && rm -f $Report
    mysql=( mysql --protocol=socket -uroot )
    Uid=$(id -u mysql)

    rm -fr $RecoveryArea/*

    echo "$(date '+%m/%d %H:%M:%S'): Recovering Database files"
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$SnapShotDir", \
        "uid": "$Uid", \
        "time": "$Time" \
    }
EOF
    for i in $DataDir/*; do ln -s $i /var/lib/mysql; done

    echo -e "\n$(date '+%m/%d %H:%M:%S'): Recovery report for $HOSTNAME:\n" >>$Report
    cat $RecoveryDir/backup.status 2>&1 | tee -a $Report

    echo "$(date '+%m/%d %H:%M:%S'): Checking Database innodb file integrity"
    innochecksum /var/lib/mysql/ibdata*
    RC=$? # save rc because date command below overwrites it
    echo "$(date '+%m/%d %H:%M:%S'): Checking Database innodb file integrity ended with exitcode $RC" | tee -a $Report
    [ $RC -ne 0 ] && exit $RC

    echo "$(date '+%m/%d %H:%M:%S'): Starting MySQL Server"
    # Do not open tcp socket yet
    coproc tailcop { exec /usr/local/bin/docker-entrypoint.sh --skip-grant-tables --skip-networking 2>&1 ; }

    while read -ru ${tailcop[0]} line; do
     echo $line
     [ $(expr "$line" : '.*InnoDB: 5.5.57 started; log sequence number') -gt 0 ] && echo $line >>$Report
     [ $(expr "$line" : '.*\[Note\] mysqld: ready for connections.') -gt 0 ] && break
    done
    sleep 1

    # Display output of mysqld during recovery
    exec 3<&${tailcop[0]}
    cat <&3 &

    echo "$(date '+%m/%d %H:%M:%S'): Recover binary logs"
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$BinLogDir/binlog.index", \
        "uid": "$Uid", \
        "time": "$Time" \
    }
EOF
    firstlog=( $(egrep '^binlog\.[0-9]+\s[0-9]+$' $RecoveryDir/backup.status) )
    # firstlog[0] : filename of binlog during backup"
    # firstlog[1] : position in the firstlog during backup snapshot
    args=( "-j ${firstlog[1]}" )
    [ "$Time" != "null" ] && args+=( "--stop-datetime='$Time'" )
    while read -r file; do
        [ "${firstlog[0]}" != $(basename $file) ] && continue; #skip until first log
        while read -r file; do
            # add binlog to argument list and recover it
            args+=( "$RecoveryArea/$(basename $file)" )
            echo "$(date '+%m/%d %H:%M:%S'): Recovering binlog: $file"
            cat <<-EOF | socat -,ignoreeof $RecoverySocket
            { \
                "client": "$HOSTNAME", \
                "path": "$file", \
                "uid": "$Uid" \
            }
EOF
        done
    done <$RecoveryArea/binlog.index

    echo "$(date '+%m/%d %H:%M:%S'): Applying binlogs: ${args[@]}" | tee -a $Report
    eval mysqlbinlog ${args[@]} | ${mysql[@]}
    # mysqlbinlog does not give non-zero return code when it fails

    # Check datebase table integrity
    echo "$(date '+%m/%d %H:%M:%S'): Checking Database table integrity"
    mysqlcheck --user=root --all-databases
    RC=$?
    echo "$(date '+%m/%d %H:%M:%S'): Checking Database table integrity ended with exitcode $RC" | tee -a $Report
    [ $RC -ne 0 ] && exit $RC

    # Create Test User, etc ..."
    # This flushes privileges!
    recoverytestuser.sh
    for f in /docker-entrypoint-initdb.d/*.sql; do
        echo "$0: running $f"
    	eval ${mysql[@]} < "$f"
    done

    # Shutdown
    pkill -x cat  # Stop reading mysqld output in order to sync on shutdown
    echo "$(date '+%m/%d %H:%M:%S'): Shutting down MySQL Server"
    kill $tailcop_PID
    cat <&${tailcop[0]}  # Wait for shutdown while showing progress
    exit 0
else
    # Delegate control to the docker-io/mysql container implementation
    exec /usr/local/bin/docker-entrypoint.sh mysqld
fi
