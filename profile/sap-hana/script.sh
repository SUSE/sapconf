#!/bin/bash
# shellcheck disable=SC1091,SC2068

# Optimise kernel parameters for running SAP HANA and HANA based products (such as Business One).
# The calculations are based on:
# - Parameters tuned by SAP installation wizard and configure_HANA.sh.
# - Various SAP Notes.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

start() {
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
        sysctl -w net.ipv4.tcp_slow_start_after_idle="$TCP_SLOW_START"
    else
        log "Leaving net.ipv4.tcp_slow_start_after_idle unchanged at $cur_val"
    fi

    # SAP Note 2205917 - KSM and AutoNUMA both should be off
    cur_val=$(cat /sys/kernel/mm/ksm/run)
    KSM=$(chk_conf_val KSM "$cur_val")
    if [ "$cur_val" != "$KSM" ]; then
        save_value ksm "$cur_val"
        log "Change ksm from $cur_val to $KSM"
        echo "$KSM" > /sys/kernel/mm/ksm/run
    else
        log "Leaving ksm unchanged at $cur_val"
    fi
    cur_val=$(cat /proc/sys/kernel/numa_balancing)
    NUMA_BALANCING=$(chk_conf_val NUMA_BALANCING "$cur_val")
    if [ "$cur_val" != "$NUMA_BALANCING" ]; then
        save_value numa_balancing "$cur_val"
        log "Change numa_balancing from $cur_val to $NUMA_BALANCING"
        echo "$NUMA_BALANCING" > /proc/sys/kernel/numa_balancing
    else
        log "Leaving numa_balancing unchanged at $cur_val"
    fi

    # SAP Note 2205917 - Transparent Hugepage should be never
    # SAP Note 2055470 - Ignore transparent huge pages and c-state information given in the first two notes above. These technologies are different on IBM Power Servers. (Version 68 from Oct 11, 2017)
    if [[ $(uname -m) == x86_64 ]]; then
        cur_val=$(sed 's%.*\[\(.*\)\].*%\1%' /sys/kernel/mm/transparent_hugepage/enabled)
        THP=$(chk_conf_val THP "$cur_val")
        if [ "$cur_val" != "$THP" ]; then
            save_value thp "$cur_val"
            log "Change transparent_hugepage from $cur_val to $THP"
            echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled
        else
            log "Leaving transparent_hugepage unchanged at $cur_val"
        fi
    fi

    log "--- Finished application of SAP tuning techniques"
    return 0
}

stop() {
    log "--- Going to revert SAP tuned parameters"

    revert_preparation
    revert_page_cache_limit
    #revert_shmmni

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
        [ "$TVAL" ] && log "Restoring $rest_value=$TVAL" && sysctl -w "$rest_value=$TVAL"
    done

    # Restore THP, KSM and AutoNUMA settings
    if [[ $(uname -m) == "x86_64" ]]; then
        THP=$(restore_value thp)
        [ "$THP" ] && log "Restoring thp=$THP" && echo "$THP"  > /sys/kernel/mm/transparent_hugepage/enabled
    fi

    KSM=$(restore_value ksm)
    [ "$KSM" ] && log "Restoring ksm=$KSM" && echo "$KSM" > /sys/kernel/mm/ksm/run
    NUMA_BALANCING=$(restore_value numa_balancing)
    [ "$NUMA_BALANCING" ] && log "Restoring numa_balancing=$NUMA_BALANCING" && echo "$NUMA_BALANCING" > /proc/sys/kernel/numa_balancing

    log "--- Finished reverting SAP tuned parameters"
    return 0
}

process $@
