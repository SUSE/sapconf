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
    log "--- Going to apply universal tuning techniques"

    # Bunch of variables declared in upper case
    # VSZ_TMPFS_PERCENT is by default 75, sysconfig file may override this value.
    declare VSZ_TMPFS_PERCENT=75
    declare TMPFS_SIZE_REQ=0

    # semaphore variables
    declare SEMMSLCUR
    declare SEMMNSCUR
    declare SEMOPMCUR
    declare SEMMNICUR

    # Read value requirements from sysconfig, the declarations will set variables above.
    if [ -r /etc/sysconfig/sapconf ]; then
        source /etc/sysconfig/sapconf
    else
        log 'Failed to read /etc/sysconfig/sapconf'
        exit 1
    fi

    # paranoia: should not happen, because post script of package installation
    # should rewrite variable names. But....
    for par in SHMALL_MIN SHMMAX_MIN SEMMSL_MIN SEMMNS_MIN SEMOPM_MIN SEMMNI_MIN MAX_MAP_COUNT_DEF SHMMNI_DEF DIRTY_BYTES_DEF DIRTY_BG_BYTES_DEF; do
        npar=${par%_*}
        if [ -n "$par" -a -z "$npar" ]; then
            # the only interesting case:
            # the old variable name is declared in the sysconfig file, but the
            # NOT the new variable name
            # So set the new variable name  with the value of the old one
            declare $npar=${!par}
        fi
    done

    ## Collect current information

    # semaphore settings
    read -r SEMMSLCUR SEMMNSCUR SEMOPMCUR SEMMNICUR < <(sysctl -n kernel.sem)
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

    ## Calculate recommended value

    # 1275776 - Preparing SLES for SAP
    declare -r VSZ=$(awk -v t=0 '/^(Mem|Swap)Total:/ {t+=$2} END {print t}' < /proc/meminfo) # total (system+swap) memory size in KB
    declare -r PSZ=$(getconf PAGESIZE)
    declare TMPFS_SIZE_REQ=$(math "$VSZ*$VSZ_TMPFS_PERCENT/100")

    ## Apply new parameters

    # Enlarge tmpfs
    if [ $(math_test "$TMPFS_SIZE_REQ > $TMPFS_SIZE") ]; then
        log "Increasing size of /dev/shm from $TMPFS_SIZE to $TMPFS_SIZE_REQ"
        save_value tmpfs.size "$TMPFS_SIZE"
        save_value tmpfs.mount_opts "$TMPFS_OPTS"
        mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE_REQ}k" /dev/shm
    elif [ $(math_test "$TMPFS_SIZE_REQ <= $TMPFS_SIZE") ]; then
        log "Leaving size of /dev/shm untouched at $TMPFS_SIZE"
    fi
    # Tweak shm
    save_value kernel.shmmax $(sysctl -n kernel.shmmax)
    chk_and_set_conf_val SHMMAX kernel.shmmax
    save_value kernel.shmall $(sysctl -n kernel.shmall)
    chk_and_set_conf_val SHMALL kernel.shmall
    # Tweak semaphore
    save_value kernel.sem "$(sysctl -n kernel.sem)"
    SEMMSL=$(chk_conf_val SEMMSL $SEMMSLCUR)
    SEMMNS=$(chk_conf_val SEMMNS $SEMMNSCUR)
    SEMOPM=$(chk_conf_val SEMOPM $SEMOPMCUR)
    SEMMNI=$(chk_conf_val SEMMNI $SEMMNICUR)
    log "Set kernel.sem to '$SEMMSL $SEMMNS $SEMOPM $SEMMNI'"
    sysctl -w "kernel.sem=$SEMMSL $SEMMNS $SEMOPM $SEMMNI"
    # Tweak max_map_count
    save_value vm.max_map_count $(sysctl -n vm.max_map_count)
    chk_and_set_conf_val MAX_MAP_COUNT vm.max_map_count

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

    log "--- Finished application of universal tuning techniques"
}

# revert_preparation reverts tuning operations conducted by "1275776 - Preparing SLES for SAP" and "1984787 - Installation notes".
revert_preparation() {
    log "--- Going to revert universally tuned parameters"
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
    log "--- Finished reverting universally tuned parameters"
}

# tune_uuidd_socket unconditionally enables and starts uuidd.socket as recommended in "1984787 - Installation notes".
tune_uuidd_socket() {
    log "--- Going to enable uuidd.socket"
    if ! systemctl is-active uuidd.socket; then
        save_value uuidd 1
        systemctl enable uuidd.socket
        systemctl start uuidd.socket
    fi
}

# revert_uuidd_socket reverts uuidd.socket to disabled state.
revert_uuidd_socket() {
    UUIDD=$(restore_value uuidd)
    [ "$UUIDD" ] && log "Revert uuidd.socket to disabled state" && systemctl disable uuidd.socket && systemctl stop uuidd.socket
}

# revert_shmmni reverts kernel.shmmni value to previous state.
revert_shmmni() {
    SHMMNI=$(restore_value kernel.shmmni)
    [ "$SHMMNI" ] && log "Restoring kernel.shmmni=$SHMMNI" && sysctl -w "kernel.shmmni=$SHMMNI"
}
