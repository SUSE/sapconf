#!/bin/bash
# Optimise kernel parameters, tmpfs, and system limits for running SAP Netweaver products.
# The calculations are based on:
# - Parameters tuned by the traditional "sapconf" package.
# - Various SAP notes.
# For SAP HANA tuning, please use "sap-hana" profile instead of this one.
# Authors: Howard Guo <hguo@suse.com>

. /usr/lib/tuned/functions

math() {
  echo $* | bc | tr -d '\n'
}

math_test() {
  [ $(echo $* | bc | tr -d '\n') = '1' ] && echo -n 1
}

start() {
    # Read total memory size (including swap) in KBytes
    declare -r VSZ=$(awk -v t=0 '/^(Mem|Swap)Total:/ {t+=$2} END {print t}' < /proc/meminfo)
    declare -r PSZ=$(getconf PAGESIZE)

    # These names are the tuning parameters
    declare -r TUNED_VARS="TMPFS_SIZE SHMALL SEMMSL SEMMNS SEMOPM SEMMNI SHMMAX MAX_MAP_COUNT"
    for name in $TUNED_VARS; do
        # Current value
        declare $name=0
        # Calculated recommended value / future value
        declare ${name}_REQ=0
        # Minimum boundary is set set in sysconfig/sapconf
        declare ${name}_MIN=0
    done

    # Read current kernel tuning values from sysctl
    declare SHMMAX=$(sysctl -n kernel.shmmax)
    declare SHMALL=$(sysctl -n kernel.shmall)
    declare MAX_MAP_COUNT=$(sysctl -n vm.max_map_count)
    read -r SEMMSL SEMMNS SEMOPM SEMMNI < <(sysctl -n kernel.sem)

    # Read current tmpfs mount options and size
    read discard discard discard TMPFS_OPTS discard < <(grep -E '^tmpfs /dev/shm .+' /proc/mounts)
    if [ ! "$TMPFS_OPTS" ]; then
        echo "The system does not use tmpfs. Please configure tmpfs and try again." 1>&2
        exit 1
    fi
    # Remove size= from mount options
    TMPFS_OPTS=$(echo "$TMPFS_OPTS" | sed 's/size=[^,]\+//' | sed 's/^,//' | sed 's/,$//' | sed 's/,,/,/')
    declare -i TMPFS_SIZE=$(($(stat -fc '(%b*%S)>>10' /dev/shm))) # in KBytes

    # Read minimal value requirements from sysconfig
    if [ -r /etc/sysconfig/sapconf ]; then
        source /etc/sysconfig/sapconf
    fi

    # Calculate tuning parameter recommendations according to SAP notes
    declare SHMALL_REQ=$( math "$VSZ*1024/$PSZ" ) # Note 941735: kernel.shmall is in pages; 20GB
    declare SHMMAX_REQ=$( math "$VSZ*1024" ) # Note 941735:  kernel.shmmax is in Bytes: 20GB
    declare TMPFS_SIZE_REQ=$( math "$VSZ*$VSZ_TMPFS_PERCENT/100" ) # Note 941735: size of tmpfs in KB (RAM + SWAP) * 0.75

    # No value may go below minimal
    for name in $TUNED_VARS; do
        min=${name}_MIN
        req=${name}_REQ
        val=${!name}
        if [ ! "${!req}" -o $( math_test "${!req} < $val" ) ]; then
            declare -i $req="$val"
        fi
        if [ $( math_test "${!req} < ${!min}" ) ]; then
            declare -i $req="${!min}"
        fi
    done

    # Tune tmpfs - enlarge if necessary
    save_value tmpfs.size "$TMPFS_SIZE"
    save_value tmpfs.mount_opts "$TMPFS_OPTS"
    if [ "$TMPFS_SIZE_REQ" -gt "$TMPFS_SIZE" ]; then
        mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE_REQ}k" /dev/shm
    fi

    # Tune kernel parameters
    save_value kernel.shmmax "$SHMMAX"
    save_value kernel.sem "$(sysctl -n kernel.sem)"
    save_value kernel.shmall "$SHMALL"
    save_value vm.max_map_count "$MAX_MAP_COUNT"
    sysctl -w kernel.shmmax="$SHMMAX_REQ"
    sysctl -w kernel.sem="$SEMMSL_REQ $SEMMNS_REQ $SEMOPM_REQ $SEMMNI_REQ"
    sysctl -w kernel.shmall="$SHMALL_REQ"
    sysctl -w vm.max_map_count="$MAX_MAP_COUNT_REQ"

    # Tune ulimits for the max number of open files (rollback is not necessary in stop function)
    all_nofile_limits=""
    for limit in ${!LIMIT_*}; do # LIMIT_ parameters originate from sysconf/sapconf
        all_nofile_limits="$all_nofile_limits\n${!limit}"
    done
    for ulimit_group in @sapsys @sdba @dba; do
        for ulimit_type in soft hard; do
            sysconf_line=$(echo -e "$all_nofile_limits" | grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+")
            limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+" /etc/security/limits.conf)
            if [ "$limits_line" ]; then
                sed -i "/$limits_line/d" /etc/security/limits.conf
            fi
            echo "$sysconf_line" >> /etc/security/limits.conf
        done
    done

    # SAP note 1557506 - Linux paging improvements
    source /etc/sysconfig/sapnote-1557506
    declare -r PAGECACHE_LIMIT=$(sysctl -n vm.pagecache_limit_mb)
    if [ "$ENABLE_PAGECACHE_LIMIT" = "yes" ]; then
		# Note that the calculation is different from HANA's algorithm, and it is based on system RAM size instead of VSZ.
		declare -r MEMSIZE_GB=$( math "$(grep MemTotal /proc/meminfo | awk '{print $2}')/1024/1024" )
		declare -i PAGECACHE_LIMIT=$(sysctl -n vm.pagecache_limit_mb)
		if [ $( math_test "$MEMSIZE_GB < 16" ) ]; then
		    declare PAGECACHE_LIMIT_NEW=512
		elif [ $( "$MEMSIZE_GB < 32" ) ]; then
		    declare PAGECACHE_LIMIT_NEW=1024
		elif [  $( "$MEMSIZE_GB < 64" ) ]; then
		    declare PAGECACHE_LIMIT_NEW=2048
		else
		    declare PAGECACHE_LIMIT_NEW=4096
		fi
        # If override is present, use the override value.
        [ "$OVERRIDE_PAGECACHE_LIMIT_MB" ] && declare PAGECACHE_LIMIT_NEW="$OVERRIDE_PAGECACHE_LIMIT_MB"
        save_value vm.pagecache_limit_mb "$PAGECACHE_LIMIT"
        sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT_NEW"
        # Set ignore_dirty
        save_value vm.pagecache_limit_ignore_dirty $(sysctl -n vm.pagecache_limit_ignore_dirty)
        sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
    else
        # Disable pagecache limit by setting it to 0
        save_value vm.pagecache_limit_mb "$PAGECACHE_LIMIT"
        sysctl -w "vm.pagecache_limit_mb=0"
    fi

    # SAP note 1984787 - Installation notes
    # Turn on UUIDD
    if ! systemctl is-active uuidd.socket; then
        save_value uuidd 1
        systemctl enable uuidd.socket
        systemctl start uuidd.socket
    fi

    return 0
}

stop() {
    # Restore tuned kernel parameters
    SHMMAX=$(restore_value kernel.shmmax)
    SEM=$(restore_value kernel.sem)
    SHMALL=$(restore_value kernel.shmall)
    MAX_MAP_COUNT=$(restore_value vm.max_map_count)
    [ "$SHMMAX" ] && sysctl -w kernel.shmmax="$SHMMAX"
    [ "$SHMALL" ] && sysctl -w kernel.shmall="$SHMALL"
    [ "$SEM" ] && sysctl -w kernel.sem="$SEM"
    [ "$MAX_MAP_COUNT" ] && sysctl -w vm.max_map_count="$MAX_MAP_COUNT"

    # Restore the size of tmpfs
    TMPFS_SIZE=$(restore_value tmpfs.size)
    TMPFS_OPTS=$(restore_value tmpfs.mount_opts)
    [ "$TMPFS_SIZE" -a -e /dev/shm ] && mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE}k" /dev/shm

    # Restore pagecahce settings
    PAGECACHE_LIMIT=$(restore_value vm.pagecache_limit_mb)
    [ "$PAGECACHE_LIMIT" ] && sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT"
    PAGECACHE_LIMIT_IGNORE_DIRTY=$(restore_value vm.pagecache_limit_ignore_dirty)
    [ "$PAGECACHE_LIMIT_IGNORE_DIRTY" ] && sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"

    # Restore UUIDD
    UUIDD=$(restore_value uuidd)
    [ "$UUIDD" ] && systemctl disable uuidd.socket && systemctl stop uuidd.socket

    return 0
}

process $@
