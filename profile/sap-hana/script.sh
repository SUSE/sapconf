#!/bin/bash
# Optimise kernel parameters for running SAP HANA and HANA based products (such as Business One).
# The calculations are based on:
# - Parameters tuned by SAP installation wizard and configure_HANA.sh.
# - Various SAP notes.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

start() {
    log "--- Going to apply HANA tuning techniques"
    # Common tuning techniques apply to HANA
    tune_preparation
    # SAP note 1557506 - Linux paging improvements
    tune_page_cache_limit_hana
    # SAP note 1984787 - Installation notes
    tune_uuidd_socket

    tune_shmmni_hana

    # SAP note 2205917 - KSM and AutoNUMA both should be off
    save_value ksm "$(cat /sys/kernel/mm/ksm/run)"
    echo 0 > /sys/kernel/mm/ksm/run
    save_value numa_balancing "$(cat /proc/sys/kernel/numa_balancing)"
    echo 0 > /proc/sys/kernel/numa_balancing


    # The following parameters were specified in tuned.conf before 2017-07-25, but are removed from tuned.conf
    # because they are redundant or no formula exists to calculate them automatically:
    # vm.dirty_ratio = 10
    # vm.dirty_background_ratio = 3
    # vm.swappiness = 10
    # kernel.sem = 1250 256000 100 8192
    # kernel.sched_min_granularity_ns = 10000000
    # kernel.sched_wakeup_granularity_ns = 15000000

    log "--- Finished application of HANA tuning techniques"
    return 0
}

stop() {
    log "--- Going to revert HANA tuned parameters"

    revert_preparation
    revert_page_cache_limit
    revert_uuidd_socket
    revert_shmmni

    # Restore KSM and AutoNUMA settings
    KSM=$(restore_value ksm)
    [ "$KSM" ] && log "Restoring ksm=$KSM" && echo "$KSM" > /sys/kernel/mm/ksm/run
    NUMA_BALANCING=$(restore_value numa_balancing)
    [ "$NUMA_BALANCING" ] && log "Restoring numa_balancing=$NUMA_BALANCING" && echo "$NUMA_BALANCING" > /proc/sys/kernel/numa_balancing

    log "--- Finished reverting HANA tuned parameters"
    return 0
}

process $@
