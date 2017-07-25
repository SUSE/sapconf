#!/usr/bin/env bash

# common.sh implements common tuning techniques that are universally applied to many SAP softwares.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

. /usr/lib/tuned/functions
cd /usr/lib/sapconf || exit 1
. util.sh

# tune_preparation applies tuning techniques from "1275776 - Preparing SLES for SAP" and "1984787 - Installation notes".
tune_preparation() {
    log "Applying tuning techniques that are universally applied to many SAP softwares"

    # Bunch of variables declared in upper case
    # The _REQ variables store optimal values calculated via SAP's formula
    # The _MIN variables are minimum boundaries defined in sysconfig - quite useless really
    declare TMPFS_SIZE_REQ=0
    declare TMPFS_SIZE_MIN=0

    declare SHMALL_REQ=0
    declare SHMALL_MIN=0
    declare SHMMAX_REQ=0
    declare SHMMAX_MIN=0

    # The semaphore settings are not calculated via formula, hence they do not have _REQ variables.
    declare SEMMSL_MIN=0
    declare SEMMNS_MIN=0
    declare SEMOPM_MIN=0
    declare SEMMNI_MIN=0

    # MAX_MAP_COUNT is by default 2000000, sysconfig file may override the _MIN value.
    declare MAX_MAP_COUNT_REQ=2000000
    declare MAX_MAP_COUNT_MIN=0
    # VSZ_TMPFS_PERCENT is by default 75, sysconfig file may override this value. There is no _MIN for this variable.
    declare VSZ_TMPFS_PERCENT=75

    # Read minimal value requirements from sysconfig, the declarations will override _MIN variables above.
    if [ -r /etc/sysconfig/sapconf ]; then
        source /etc/sysconfig/sapconf
    else
        log 'Failed to read /etc/sysconfig/sapconf'
        exit 1
    fi

    # Collect current information

    # Sysctl - semaphore settings and max_map_count
    declare SEMMSL
    declare SEMMNS
    declare SEMOPM
    declare SEMMNI
    read -r SEMMSL SEMMNS SEMOPM SEMMNI < <(sysctl -n kernel.sem)
    declare MAX_MAP_COUNT=$(sysctl -n vm.max_map_count)
    # Mount - tmpfs mount options and size
    declare TMPFS_OPTS
    read discard discard discard TMPFS_OPTS discard < <(grep -E '^tmpfs /dev/shm .+' /proc/mounts)
    if [ ! "$TMPFS_OPTS" ]; then
        log "The system does not use tmpfs. Please configure tmpfs and try again."
        exit 1
    fi
    # Remove size= from mount options
    declare TMPFS_OPTS=$(echo "$TMPFS_OPTS" | sed 's/size=[^,]\+//' | sed 's/^,//' | sed 's/,$//' | sed 's/,,/,/')
    declare TMPFS_SIZE=$(($(stat -fc '(%b*%S)>>10' /dev/shm))) # in KBytes

    # Calculate recommended value

    # 1275776 - Preparing SLES for SAP
    declare -r VSZ=$(awk -v t=0 '/^(Mem|Swap)Total:/ {t+=$2} END {print t}' < /proc/meminfo) # total (system+swap) memory size in KB
    declare -r PSZ=$(getconf PAGESIZE)
    declare SHMALL_REQ=$(math "$VSZ*1024/$PSZ")
    declare SHMMAX_REQ=$(math "$VSZ*1024")
    declare TMPFS_SIZE_REQ=$(math "$VSZ*$VSZ_TMPFS_PERCENT/100")
    # Some of the recommended values are coded in the sysconfig file in _MIN variables
    # The minimal values are redundant in nature, they no longer exist in saptune.
    TMPFS_SIZE_REQ=$(increase_val "TMPFS_SIZE_REQ" "$TMPFS_SIZE_REQ" "$TMPFS_SIZE_MIN")
    MAX_MAP_COUNT_REQ=$(increase_val "MAX_MAP_COUNT_REQ" "$MAX_MAP_COUNT_REQ" "$MAX_MAP_COUNT_MIN")
    SHMALL_REQ=$(increase_val "SHMALL_REQ" "$SHMALL_REQ" "$SHMALL_MIN")
    SHMMAX_REQ=$(increase_val "SHMMAX_REQ" "$SHMMAX_REQ" "$SHMMAX_MIN")
    # There is only one semaphore control variable and it has four fields, so deal with each field separately.
    SEMMSL=$(increase_val "SEMMSL" "$SEMMSL" "$SEMMSL_MIN")
    SEMMNS=$(increase_val "SEMMNS" "$SEMMNS" "$SEMMNS_MIN")
    SEMOPM=$(increase_val "SEMOPM" "$SEMOPM" "$SEMOPM_MIN")
    SEMMNI=$(increase_val "SEMMNI" "$SEMMNI" "$SEMMNI_MIN")

    # Apply new parameters

    # Enlarge tmpfs
    if [ $(math_test "$TMPFS_SIZE_REQ > $TMPFS_SIZE") ]; then
        save_value tmpfs.size "$TMPFS_SIZE"
        save_value tmpfs.mount_opts "$TMPFS_OPTS"
        mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE_REQ}k" /dev/shm
    fi
    # Tweak shm
    save_value kernel.shmmax $(sysctl -n kernel.shmmax)
    increase_sysctl kernel.shmmax "$SHMMAX_REQ"
    save_value kernel.shmall $(sysctl -n kernel.shmall)
    increase_sysctl kernel.shmall "$SHMALL_REQ"
    # Tweak semaphore
    save_value kernel.sem $(sysctl -n kernel.sem)
    sysctl -w kernel.sem "$SEMMSL $SEMMNS $SEMOPM $SEMMNI"
    # Tweak max_map_count
    save_value vm.max_map_count $(sysctl -n vm.max_map_count)
    increase_sysctl vm.max_map_count "$MAX_MAP_COUNT_REQ"

    # Tune ulimits for the max number of open files (rollback is not necessary in revert function)
    all_nofile_limits=""
    # keep syntax checker happy, otherwise checker complains that LIMIT_ is undefined in the next line.
    declare LIMIT_
    for limit in ${!LIMIT_*}; do # LIMIT_ parameters are defined in sysconfig file
        all_nofile_limits="$all_nofile_limits\n${!limit}"
    done
    for ulimit_group in @sapsys @sdba @dba; do
        for ulimit_type in soft hard; do
            sysconf_line=$(echo -e "$all_nofile_limits" | grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+")
            limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+" /etc/security/limits.conf)
            # Remove previously entered limits line so that new line may be inserted
            if [ "$limits_line" ]; then
                sed -i "/$limits_line/d" /etc/security/limits.conf
            fi
            echo "$sysconf_line" >> /etc/security/limits.conf
        done
    done

   # Amend logind's behaviour (bsc#1031355, bsc#1039309, bsc#1043844), there is no rollback in revert function.
   log "Set the maximum number of OS tasks each user may run concurrently (UserTasksMax) to 'infinity'"
   mkdir -p /etc/systemd/logind.conf.d
   echo "[Login]
UserTasksMax=infinity" > /etc/systemd/logind.conf.d/sap.conf
    log "Please reboot the system for the UserTasksMax change to become effective"
}

# Revert some tuning operations conducted by "1275776 - Preparing SLES for SAP" and "1984787 - Installation notes".
revert_preparation() {
    # Restore tuned kernel parameters
    SHMMAX=$(restore_value kernel.shmmax)
    [ "$SHMMAX" ] && log "Restoring kernel.shmmax=$SHMMAX" && sysctl -w kernel.shmmax="$SHMMAX"


    SHMALL=$(restore_value kernel.shmall)
    [ "$SHMALL" ] && log "Restoring kernel.shmall=$SHMALL" && sysctl -w kernel.shmall="$SHMALL"

    SEM=$(restore_value kernel.sem)
    [ "$SEM" ] && log "Restoring kernel.sem=$SEM" && sysctl -w kernel.sem="$SEM"

    MAX_MAP_COUNT=$(restore_value vm.max_map_count)
    [ "$MAX_MAP_COUNT" ] && log "Restoring vm.max_map_count=$MAX_MAP_COUNT" && sysctl -w vm.max_map_count="$MAX_MAP_COUNT"

    # Restore the size of tmpfs
    TMPFS_SIZE=$(restore_value tmpfs.size)
    TMPFS_OPTS=$(restore_value tmpfs.mount_opts)
    [ "$TMPFS_SIZE" -a -e /dev/shm ] && mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE}k" /dev/shm
}
