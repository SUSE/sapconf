#!/bin/bash
# Optimise kernel parameters, tmpfs, and system limits for running SAP Netweaver products.
# The calculations are based on:
# - Parameters tuned by the traditional "sapconf" package.
# - Various SAP notes.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

start() {
    log "--- Going to apply Netweaver tuning techniques"
    # The common tuning techniques apply here
    tune_preparation
    # SAP note 1557506 - Linux paging improvements
    tune_page_cache_limit_netweaver
    # SAP note 1984787 - Installation notes
    tune_uuidd_socket

    # The following parameters were specified in tuned.conf before 2017-07-25, but are removed from tuned.conf
    # because they are redundant or no formula exists to calculate them automatically:
    # kernel.sched_min_granularity_ns = 10000000
    # kernel.sched_wakeup_granularity_ns = 15000000
    # vm.dirty_ratio = 10
    # vm.dirty_background_ratio = 3
    # vm.swappiness = 10

    log "--- Finished application of Netweaver tuning techniques"
    return 0
}

stop() {
    log "--- Going to revert Netweaver tuned parameters"
    revert_preparation
    revert_page_cache_limit
    revert_uuidd_socket
    log "--- Finished reverting Netweaver tuned parameters"
    return 0
}

process $@
