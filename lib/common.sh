#!/bin/sh

# Common tuning functions that are useful to both SAP Netweaver and HANA.

. /usr/lib/tuned/functions

# Invoke bc arbitrary precision calculator.
math() {
  echo $* | bc | tr -d '\n'
}

# Invoke bc arbitrary precision calculator to do a comparison. Return "1" if comparison is truthy.
math_test() {
  [ $(echo $* | bc | tr -d '\n') = '1' ] && echo -n 1
}

# Tune system according to 1275776 - Preparing SLES for SAP and 1984787 - Installation notes.
tune_preparation() {
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
    declare TMPFS_SIZE=$(($(stat -fc '(%b*%S)>>10' /dev/shm))) # in KBytes

    # Read minimal value requirements from sysconfig
    if [ -r /etc/sysconfig/sapconf ]; then
        source /etc/sysconfig/sapconf
    else
        echo 'Failed to read /etc/sysconfig/sapconf'
        exit 1
    fi

    # Calculate tuning parameter recommendations according to SAP notes
    declare SHMALL_REQ=$( math "$VSZ*1024/$PSZ" )
    declare SHMMAX_REQ=$( math "$VSZ*1024" )
    declare TMPFS_SIZE_REQ=$( math "$VSZ*$VSZ_TMPFS_PERCENT/100" )

    # No value may drop below manually defined minimal or the current value
    # TODO: Think about why the minimal value is needed, saptune does not use them anymore.
    for name in $TUNED_VARS; do
        min=${name}_MIN
        req=${name}_REQ
        val=${!name}
        if [ ! "${!req}" -o $( math_test "${!req} < $val" ) ]; then
            declare $req="$val"
        fi
        if [ $( math_test "${!req} < ${!min}" ) ]; then
            declare $req="${!min}"
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

    # Tune ulimits for the max number of open files (rollback is not necessary in revert function)
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
}

# Revert tuning operations conducted by 1275776 - Preparing SLES for SAP and 1984787 - Installation notes.
revert_preparation() {
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
}
