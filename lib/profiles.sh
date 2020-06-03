#!/usr/bin/env bash
# shellcheck disable=SC1091

# profile.sh implements special tuning techniques that are applied to specific SAP softwares.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

# Optimise kernel parameters for running SAP HANA and HANA based products (such as Business One).
# The calculations are based on:
# - Parameters tuned by SAP installation wizard and configure_HANA.sh.
# - Various SAP Notes.
#
# tune_hana applies tuning techniques for SAP HANA workloads
# tune_hana is the same as tune_netweaver
tune_hana() {
    tune_netweaver
}
revert_hana() {
    revert_netweaver
}

# tune_netweaver applies tuning techniques for S4/HANA and Netweaver workloads
tune_netweaver() {
    log "--- Going to apply SAP tuning techniques"
    # Common tuning techniques apply to HANA and NetWeaver
    tune_preparation
    # SAP Note 1557506 - Linux paging improvements
    tune_page_cache_limit
    # SAP Note 1984787 - Installation notes
    tune_uuidd_socket

    # Read value requirements from sysconfig
    # if value is not set in sysconfig file, log a message and keep the
    # current system value
    if [ -r /etc/sysconfig/sapconf ]; then
        source_sysconfig /etc/sysconfig/sapconf
    else
        log 'Failed to read /etc/sysconfig/sapconf'
        exit 1
    fi

    # paranoia: should not happen, because post script of package installation
    # should rewrite variable names. But....
    for par in SHMMNI_DEF DIRTY_BYTES_DEF DIRTY_BG_BYTES_DEF; do
        npar=${par%_*}
        if [ -n "${!par}" ] && [ -z "${!npar}" ]; then
            # the only interesting case:
            # the old variable name is declared in the sysconfig file, but
            # NOT the new variable name
            # So set the new variable name  with the value of the old one
            declare $npar=${!par}
        fi
    done

    # SAP Note 2534844
    save_value kernel.shmmni "$(sysctl -n kernel.shmmni)"
    chk_and_set_conf_val SHMMNI kernel.shmmni

    # SAP Note 1984787
    ps=$(getconf PAGESIZE)
    [ ! "$ps" ] && ps=4096 # fallback and set a default
    min_val=$(math "$ps * 2")
    if [ "$DIRTY_BYTES" != "" ] && [ "$DIRTY_BYTES" -lt "$min_val" ]; then
        log "ATTENTION: wrong value set in sysconfig file for 'DIRTY_BYTES'. It's '$DIRTY_BYTES', but need to be at least '$min_val'"
        log "Leaving vm.dirty_bytes unchanged"
    else
        save_value vm.dirty_bytes "$(sysctl -n vm.dirty_bytes)"
        save_value vm.dirty_ratio "$(sysctl -n vm.dirty_ratio)" # value needed for revert of vm.dirty_bytes
        chk_and_set_conf_val DIRTY_BYTES vm.dirty_bytes
    fi
    if [ "$DIRTY_BG_BYTES" != "" ] && [ "$DIRTY_BG_BYTES" -eq 0 ]; then
        log "ATTENTION: wrong value set in sysconfig file for 'DIRTY_BG_BYTES'. It's set to '0', but needs to be >0"
        log "Leaving vm.dirty_background_bytes unchanged"
    else
        save_value vm.dirty_background_bytes "$(sysctl -n vm.dirty_background_bytes)"
        save_value vm.dirty_background_ratio "$(sysctl -n vm.dirty_background_ratio)" # value needed for revert of vm.dirty_background_bytes
        chk_and_set_conf_val DIRTY_BG_BYTES vm.dirty_background_bytes
    fi

    # SAP Note 2382421
    cur_val=$(sysctl -n net.ipv4.tcp_slow_start_after_idle)
    TCP_SLOW_START=$(chk_conf_val TCP_SLOW_START "$cur_val")
    if [ "$cur_val" != "$TCP_SLOW_START" ]; then
        save_value net.ipv4.tcp_slow_start_after_idle "$cur_val"
        log "Change net.ipv4.tcp_slow_start_after_idle from $cur_val to $TCP_SLOW_START"
        sysctl -q -w net.ipv4.tcp_slow_start_after_idle="$TCP_SLOW_START"
    else
        log "Leaving net.ipv4.tcp_slow_start_after_idle unchanged at $cur_val"
    fi

    # SAP Note 2205917 - KSM and AutoNUMA both should be off
    save_and_set_sys_val ksm /sys/kernel/mm/ksm/run
    save_and_set_sys_val numa_balancing /proc/sys/kernel/numa_balancing

    # SAP Note 2205917 - Transparent Hugepage should be never
    # SAP Note 2055470 - Ignore transparent huge pages and c-state information given in the first two notes above. These technologies are different on IBM Power Servers. (Version 68 from Oct 11, 2017)
    # the restriction for Power systems was removed from the SAP Note with Version 69 from 15.03.2018
    cur_val=$(sed 's%.*\[\(.*\)\].*%\1%' /sys/kernel/mm/transparent_hugepage/enabled)
    THP=$(chk_conf_val THP "$cur_val")
    if [ "$cur_val" != "$THP" ]; then
        save_value thp "$cur_val"
        log "Change transparent_hugepage from $cur_val to $THP"
        echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled
    else
        log "Leaving transparent_hugepage unchanged at $cur_val"
    fi
    if [[ $(uname -m) == x86_64 ]]; then
        # SAP Note 2205917 - performance settings
        set_performance_settings
    fi

    log "--- Finished application of SAP tuning techniques"
    return 0
}

revert_netweaver() {
    log "--- Going to revert SAP tuning parameters"

    revert_preparation
    revert_page_cache_limit

    # Restore kernel.shmmni, vm.dirty_bytes, vm.dirty_background_bytes, net.ipv4.tcp_slow_start_after_idle
    # to revert vm.dirty_bytes first revert vm.dirty_ratio
    # to revert vm.dirty_background_ratio (reset during set of vm.dirty_background_bytes)
    # first revert vm.dirty_background_bytes, then vm.dirty_background_ratio
    for rest_value in kernel.shmmni vm.dirty_ratio vm.dirty_bytes vm.dirty_background_bytes vm.dirty_background_ratio net.ipv4.tcp_slow_start_after_idle; do
        TVAL=$(restore_value $rest_value)
        [ ! "$TVAL" ] && continue
        case "$rest_value" in
        vm.dirty_ratio|vm.dirty_background_bytes|vm.dirty_background_ratio)
            if [ "$TVAL" -eq 0 ]; then
                TVAL=""
            fi
        ;;
        vm.dirty_bytes)
            ps=$(getconf PAGESIZE)
            [ ! "$ps" ] && ps=4096 # fallback and set a default
            min_val=$(math "$ps * 2")
            if [ "$TVAL" -eq 0 ] || [ "$TVAL" -lt "$min_val" ]; then
                TVAL=""
            fi
        ;;
        esac
        [ "$TVAL" ] && log "Restoring $rest_value=$TVAL" && sysctl -q -w "$rest_value=$TVAL"
    done

    # Restore THP, KSM and AutoNUMA settings
    THP=$(restore_value thp)
    [ "$THP" ] && log "Restoring thp=$THP" && echo "$THP"  > /sys/kernel/mm/transparent_hugepage/enabled

    KSM=$(restore_value ksm)
    [ "$KSM" ] && log "Restoring ksm=$KSM" && echo "$KSM" > /sys/kernel/mm/ksm/run
    NUMA_BALANCING=$(restore_value numa_balancing)
    [ "$NUMA_BALANCING" ] && log "Restoring numa_balancing=$NUMA_BALANCING" && echo "$NUMA_BALANCING" > /proc/sys/kernel/numa_balancing

    if [[ $(uname -m) == x86_64 ]]; then
        # restore performance settings
        restore_performance_settings
    fi

    log "--- Finished reverting SAP tuning parameters"
    return 0
}

# Optimise kernel parameters for running SAP Business OBJects (BOBJ)
#
# tune_bobj applies tuning techniques according to 
# https://uacp2.hana.ondemand.com/doc/46b1602a6e041014910aba7db0e91070/4.1.9/en-US/sbo41sp9_bip_inst_unix_en.pdf
# or https://websmp202.sap-ag.de/~sapidp/012002523100003123382016E/sbo42sp2_bip_inst_unix_en.pdf
# SAP BusinessObjects Business Intelligence platform
# Business Intelligence Platform
# Installation Guide for Unix
# section '4.1.3 Additional requirements for SUSE'
#
tune_bobj() {
    log "--- Going to apply BOBJ tuning techniques"
    # Apply tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    tune_preparation
    # SAP note 1557506 - Linux paging improvements
    tune_page_cache_limit
    # SAP note 1984787 - Installation notes
    tune_uuidd_socket

    # sysconfig/sapnote-bobj as replacement of tuned.conf
    if [ -r /etc/sysconfig/sapnote-bobj ]; then
        source_sysconfig /etc/sysconfig/sapnote-bobj
    else
        log 'Failed to read /etc/sysconfig/sapnote-bobj'
        exit 1
    fi

    save_value kernel.msgmni_bobj "$(sysctl -n kernel.msgmni)"
    chk_and_set_conf_val MSGMNI kernel.msgmni

    save_value kernel.shmmax_bobj "$(sysctl -n kernel.shmmax)"
    chk_and_set_conf_val SHMMAX kernel.shmmax

    declare SEMMSLCUR
    declare SEMMNSCUR
    declare SEMOPMCUR
    declare SEMMNICUR
    read -r SEMMSLCUR SEMMNSCUR SEMOPMCUR SEMMNICUR < <(sysctl -n kernel.sem)
    SEMMSL=$(chk_conf_val SEMMSL "$SEMMSLCUR")
    SEMMNS=$(chk_conf_val SEMMNS "$SEMMNSCUR")
    SEMOPM=$(chk_conf_val SEMOPM "$SEMOPMCUR")
    SEMMNI=$(chk_conf_val SEMMNI "$SEMMNICUR")
    if [ "$SEMMSLCUR $SEMMNSCUR $SEMOPMCUR $SEMMNICUR" != "$SEMMSL $SEMMNS $SEMOPM $SEMMNI" ]; then
        save_value kernel.sem_bobj "$(sysctl -n kernel.sem)"
        log "Change kernel.sem from '$SEMMSLCUR $SEMMNSCUR $SEMOPMCUR $SEMMNICUR' to '$SEMMSL $SEMMNS $SEMOPM $SEMMNI'"
        sysctl -q -w "kernel.sem=$SEMMSL $SEMMNS $SEMOPM $SEMMNI"
    else
        log "Leaving kernel.sem unchanged at '$SEMMSLCUR $SEMMNSCUR $SEMOPMCUR $SEMMNICUR'"
    fi

    set_readahead

    if [[ $(uname -m) == x86_64 ]]; then
        # SAP Note 2205917 - performance settings
        set_performance_settings
    fi

    log "--- Finished application of BOBJ tuning techniques"
    return 0
}

revert_bobj() {
    log "--- Going to revert BOBJ tuning parameters"
    msgmni="$(restore_value kernel.msgmni_bobj)"
    [ "$msgmni" ] && log "Restoring kernel.msgmni=$msgmni" && sysctl -q -w "kernel.msgmni=$msgmni"

    shmmax="$(restore_value kernel.shmmax_bobj)"
    [ "$shmmax" ] && log "Restoring kernel.shmmax=$shmmax" && sysctl -q -w "kernel.shmmax=$shmmax"

    sem=$(restore_value kernel.sem_bobj)
    [ "$sem" ] && log "Restoring kernel.sem=$sem" && sysctl -q -w kernel.sem="$sem"

    restore_readahead

    if [[ $(uname -m) == x86_64 ]]; then
        # restore performance settings
        restore_performance_settings
    fi
    revert_preparation
    revert_page_cache_limit

    log "--- Finished reverting BOBJ tuning parameters"
    return 0
}

# Optimise kernel parameters for running SAP ASE.
#
# tune_ase applies tuning techniques based on
# - Various SAP notes.
tune_ase() {
    log "--- Going to apply ASE tuning techniques"
    # Apply tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    tune_preparation
    # SAP note 1557506 - Linux paging improvements
    tune_page_cache_limit
    # SAP note 1984787 - Installation notes
    tune_uuidd_socket

    # SAP note 1680803 - best practice
    if [ -r /etc/sysconfig/sapnote-1680803 ]; then
        source_sysconfig /etc/sysconfig/sapnote-1680803
    else
        log 'Failed to read /etc/sysconfig/sapnote-1680803'
        exit 1
    fi

    # SAP Note 2534844, bsc#874778
    save_value kernel.shmmni "$(sysctl -n kernel.shmmni)"
    chk_and_set_conf_val SHMMNI kernel.shmmni

    # set number of requests for block devices (sdX)
    for _dev in /sys/block/sd*; do
        [[ -e $_dev ]] || break  # if no sd block device exist
        _dev_save=${_dev//\//_}
        _nrreq=$(cat "$_dev"/queue/nr_requests)
        if [ -n "$_nrreq" ] && [ -n "$NRREQ" ]; then
            if [ "$_nrreq" -ne "$NRREQ" ]; then
                save_value "$_dev_save" "$_nrreq"
                echo "$NRREQ" > "$_dev"/queue/nr_requests
            fi
        fi
    done
    # set memlock for user sybase
    if [ "$MEMLOCK" == "0" ]; then
        # calculating memlock RAM in KB - 10%
        MEMSIZE_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        MEMLOCK=$( math "$MEMSIZE_KB - ($MEMSIZE_KB *10/100)" )
    fi
    ulimit_group=sybase
    for ulimit_type in soft hard; do
        sysconf_line="${ulimit_group} ${ulimit_type} memlock $MEMLOCK"
        limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+memlock+" /etc/security/limits.conf)
        save_limit=0
        if [ "$limits_line" ]; then
            save_limit=$(${limits_line##*[[:space:]]})
            sed -i "/$limits_line/d" /etc/security/limits.conf
        fi
        echo "$sysconf_line" >> /etc/security/limits.conf
        save_value "memlock_$ulimit_type" "$save_limit"
    done

    # 1410736
    save_value net.ipv4.tcp_keepalive_time "$(sysctl -n net.ipv4.tcp_keepalive_time)"
    chk_and_set_conf_val KEEPALIVETIME net.ipv4.tcp_keepalive_time
    save_value net.ipv4.tcp_keepalive_intvl "$(sysctl -n net.ipv4.tcp_keepalive_intvl)"
    chk_and_set_conf_val KEEPALIVEINTVL net.ipv4.tcp_keepalive_intvl

    # 1680803
    save_value fs.aio-max-nr "$(sysctl -n fs.aio-max-nr)"
    chk_and_set_conf_val AIOMAXNR fs.aio-max-nr
    save_value fs.file-max "$(sysctl -n fs.file-max)"
    chk_and_set_conf_val FILEMAX fs.file-max

    # Increase Linux autotuning TCP buffer limits
    # Set max to 16MB (16777216) for 1GE and 32M (33554432) or 54M (56623104) for 10GE
    # Don't set tcp_mem itself! Let the kernel scale it based on RAM.
    save_value net.core.rmem_max "$(sysctl -n net.core.rmem_max)"
    chk_and_set_conf_val RMEMMAX net.core.rmem_max
    save_value net.core.wmem_max "$(sysctl -n net.core.wmem_max)"
    chk_and_set_conf_val WMEMMAX net.core.wmem_max
    save_value net.core.rmem_default "$(sysctl -n net.core.rmem_default)"
    chk_and_set_conf_val RMEMDEF net.core.rmem_default
    save_value net.core.wmem_default "$(sysctl -n net.core.wmem_default)"
    chk_and_set_conf_val WMEMDEF net.core.wmem_default
    save_value net.core.netdev_max_backlog "$(sysctl -n net.core.netdev_max_backlog)"
    chk_and_set_conf_val NETDEVMAXBACKLOG net.core.netdev_max_backlog

    declare TCPRMEMMINCUR
    declare TCPRMEMDEFCUR
    declare TCPRMEMMAXCUR
    read -r TCPRMEMMINCUR TCPRMEMDEFCUR TCPRMEMMAXCUR < <(sysctl -n net.ipv4.tcp_rmem)
    TCPRMEMMIN=$(chk_conf_val TCPRMEMMIN "$TCPRMEMMINCUR")
    TCPRMEMDEF=$(chk_conf_val TCPRMEMDEF "$TCPRMEMDEFCUR")
    TCPRMEMMAX=$(chk_conf_val TCPRMEMMAX "$TCPRMEMMAXCUR")
    if [ "$TCPRMEMMINCUR $TCPRMEMDEFCUR $TCPRMEMMAXCUR" != "$TCPRMEMMIN $TCPRMEMDEF $TCPRMEMMAX" ]; then
        save_value tcp_rmem_ase "$(sysctl -n net.ipv4.tcp_rmem)"
        log "Change net.ipv4.tcp_rmem from '$TCPRMEMMINCUR $TCPRMEMDEFCUR $TCPRMEMMAXCUR' to '$TCPRMEMMIN $TCPRMEMDEF $TCPRMEMMAX'"
        sysctl -q -w "net.ipv4.tcp_rmem=$TCPRMEMMIN $TCPRMEMDEF $TCPRMEMMAX"
    else
        log "Leaving net.ipv4.tcp_rmem unchanged at '$TCPRMEMMINCUR $TCPRMEMDEFCUR $TCPRMEMMAXCUR'"
    fi

    declare TCPWMEMMINCUR
    declare TCPWMEMDEFCUR
    declare TCPWMEMMAXCUR
    read -r TCPWMEMMINCUR TCPWMEMDEFCUR TCPWMEMMAXCUR < <(sysctl -n net.ipv4.tcp_wmem)
    TCPWMEMMIN=$(chk_conf_val TCPWMEMMIN "$TCPWMEMMINCUR")
    TCPWMEMDEF=$(chk_conf_val TCPWMEMDEF "$TCPWMEMDEFCUR")
    TCPWMEMMAX=$(chk_conf_val TCPWMEMMAX "$TCPWMEMMAXCUR")
    if [ "$TCPWMEMMINCUR $TCPWMEMDEFCUR $TCPWMEMMAXCUR" != "$TCPWMEMMIN $TCPWMEMDEF $TCPWMEMMAX" ]; then
        save_value tcp_wmem_ase "$(sysctl -n net.ipv4.tcp_wmem)"
        log "Change net.ipv4.tcp_wmem from '$TCPWMEMMINCUR $TCPWMEMDEFCUR $TCPWMEMMAXCUR' to '$TCPWMEMMIN $TCPWMEMDEF $TCPWMEMMAX'"
        sysctl -q -w "net.ipv4.tcp_wmem=$TCPWMEMMIN $TCPWMEMDEF $TCPWMEMMAX"
    else
        log "Leaving net.ipv4.tcp_wmem unchanged at '$TCPWMEMMINCUR $TCPWMEMDEFCUR $TCPWMEMMAXCUR'"
    fi

    # Huge Pages - vm.nr_hugepages
    save_value vm.nr_hugepages "$(sysctl -n vm.nr_hugepages)"
    chk_and_set_conf_val NUMBER_HUGEPAGES vm.nr_hugepages

    cur_val=$(sed 's%.*\[\(.*\)\].*%\1%' /sys/kernel/mm/transparent_hugepage/enabled)
    THP=$(chk_conf_val THP "$cur_val")
    if [ "$cur_val" != "$THP" ]; then
        save_value thp "$cur_val"
        log "Change transparent_hugepage from $cur_val to $THP"
        echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled
    else
        log "Leaving transparent_hugepage unchanged at $cur_val"
    fi

    save_value vm.swappiness "$(sysctl -n vm.swappiness)"
    chk_and_set_conf_val SWAPPINESS vm.swappiness

    set_readahead

    if [[ $(uname -m) == x86_64 ]]; then
        # SAP Note 2205917 - performance settings
        set_performance_settings
    fi

    log "--- Finished application of ASE tuning techniques"
    return 0
}

revert_ase() {
    log "--- Going to revert ASE tuning parameters"
    revert_preparation
    revert_page_cache_limit
    revert_shmmni

    val=$(restore_value net.ipv4.tcp_keepalive_time)
    [ "$val" ] && log "Restoring net.ipv4.tcp_keepalive_time=$val" && sysctl -q -w "net.ipv4.tcp_keepalive_time=$val"
    val=$(restore_value net.ipv4.tcp_keepalive_intvl)
    [ "$val" ] && log "Restoring net.ipv4.tcp_keepalive_intvl=$val" && sysctl -q -w "net.ipv4.tcp_keepalive_intvl=$val"

    val=$(restore_value fs.aio-max-nr)
    [ "$val" ] && log "Restoring fs.aio-max-nr=$val" && sysctl -q -w "fs.aio-max-nr=$val"
    val=$(restore_value fs.file-max)
    [ "$val" ] && log "Restoring fs.file-max=$val" && sysctl -q -w "fs.file-max=$val"

    val=$(restore_value net.core.rmem_max)
    [ "$val" ] && log "Restoring net.core.rmem_max=$val" && sysctl -q -w "net.core.rmem_max=$val"
    val=$(restore_value net.core.wmem_max)
    [ "$val" ] && log "Restoring net.core.wmem_max=$val" && sysctl -q -w "net.core.wmem_max=$val"
    val=$(restore_value net.core.rmem_default)
    [ "$val" ] && log "Restoring net.core.rmem_default=$val" && sysctl -q -w "net.core.rmem_default=$val"
    val=$(restore_value net.core.wmem_default)
    [ "$val" ] && log "Restoring net.core.wmem_default=$val" && sysctl -q -w "net.core.wmem_default=$val"
    val=$(restore_value net.core.netdev_max_backlog)
    [ "$val" ] && log "Restoring net.core.netdev_max_backlog=$val" && sysctl -q -w "net.core.netdev_max_backlog=$val"

    val=$(restore_value tcp_rmem_ase)
    [ "$val" ] && log "Restoring net.ipv4.tcp_rmem=$val" && sysctl -q -w net.ipv4.tcp_rmem="$val"
    val=$(restore_value tcp_wmem_ase)
    [ "$val" ] && log "Restoring net.ipv4.tcp_wmem=$val" && sysctl -q -w net.ipv4.tcp_wmem="$val"

    val=$(restore_value vm.nr_hugepages)
    [ "$val" ] && log "Restoring vm.nr_hugepages=$val" && sysctl -q -w "vm.nr_hugepages=$val"

    # Restore number of requests for block devices (sdX)
    #for _dev in `ls -d /sys/block/sd*`; do
    for _dev in /sys/block/sd*; do
        [[ -e $_dev ]] || break  # if no sd block device exist
        _dev_save=${_dev//\//_}
        NRREQ=$(restore_value "$_dev_save")
        [ "$NRREQ" ] && echo "$NRREQ" > "$_dev"/queue/nr_requests
    done

    # Restore memlock for user sybase
    ulimit_group=sybase
    for ulimit_type in soft hard; do
        MEMLOCK=$(restore_value memlock_$ulimit_type)
        restore_line="${ulimit_group} ${ulimit_type} memlock $MEMLOCK"
        limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+memlock+" /etc/security/limits.conf)
        if [ "$limits_line" ]; then
            sed -i "/$limits_line/d" /etc/security/limits.conf
        fi
        echo "$restore_line" >> /etc/security/limits.conf
    done

    # Restore THP
    THP=$(restore_value thp)
    [ "$THP" ] && log "Restoring thp=$THP" && echo "$THP"  > /sys/kernel/mm/transparent_hugepage/enabled

    val=$(restore_value vm.swappiness)
    [ "$val" ] && log "Restoring vm.swappiness=$val" && sysctl -q -w "vm.swappiness=$val"
    restore_readahead

    if [[ $(uname -m) == x86_64 ]]; then
        # restore performance settings
        restore_performance_settings
    fi

    log "--- Finished reverting ASE tuning parameters"
    return 0
}
