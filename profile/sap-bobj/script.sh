#!/bin/bash
# shellcheck disable=SC1091,SC2068

# Optimise kernel parameters for running SAP BOBJ

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

start() {
    log "--- Going to apply BOBJ tuning techniques"
    # Apply tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    tune_preparation
    # SAP note 1557506 - Linux paging improvements
    tune_page_cache_limit
    # SAP note 1984787 - Installation notes
    tune_uuidd_socket

    save_value kernel.msgmni "$(sysctl -n kernel.msgmni)"
    # shellcheck disable=SC2034
    MSGMNI=1024
    chk_and_set_conf_val MSGMNI kernel.msgmni

    save_value kernel.shmmax "$(sysctl -n kernel.shmmax)"
    # shellcheck disable=SC2034
    SHMMAX=18446744073709551615
    chk_and_set_conf_val SHMMAX kernel.shmmax

    log "--- Finished application of BOBJ tuning techniques"
    return 0
}

stop() {
    log "--- Going to revert BOBJ tuned parameters"
    revert_preparation
    revert_page_cache_limit

    msgmni="$(restore_value kernel.msgmni)"
    [ "$msgmni" ] && log "Restoring kernel.msgmni=$msgmni" && sysctl -w "kernel.msgmni=$msgmni"

    shmmax="$(restore_value kernel.shmmax)"
    [ "$shmmax" ] && log "Restoring kernel.shmmax=$shmmax" && sysctl -w "kernel.shmmax=$shmmax"

    log "--- Finished reverting BOBJ tuned parameters"
    return 0
}

process $@
