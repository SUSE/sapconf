#!/bin/bash
# Optimise kernel parameters, tmpfs, and system limits for running SAP Netweaver products.
# The calculations are based on:
# - Parameters tuned by the traditional "sapconf" package.
# - Various SAP notes.
# For SAP HANA tuning, please use "sap-hana" profile instead of this one.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

start() {
    # The common tuning techniques apply here
    tune_preparation
    log "Applying SAP-Netweaver tuning techniques"
    # SAP note 1557506 - Linux paging improvements
    source /etc/sysconfig/sapnote-1557506
    declare -r PAGECACHE_LIMIT=$(sysctl -n vm.pagecache_limit_mb)
    if [ "$ENABLE_PAGECACHE_LIMIT" = "yes" ]; then
		# Note that the calculation is different from HANA's algorithm, and it is based on system RAM size instead of VSZ.
		declare -r MEMSIZE_GB=$( math "$(grep MemTotal /proc/meminfo | awk '{print $2}')/1024/1024" )
		if [ $(math_test "$MEMSIZE_GB < 16") ]; then
		    declare PAGECACHE_LIMIT_NEW=512
		elif [ $(math_test "$MEMSIZE_GB < 32") ]; then
		    declare PAGECACHE_LIMIT_NEW=1024
		elif [  $(math_test "$MEMSIZE_GB < 64") ]; then
		    declare PAGECACHE_LIMIT_NEW=2048
		else
		    declare PAGECACHE_LIMIT_NEW=4096
		fi
        # If override is present, use the override value.
        [ "$OVERRIDE_PAGECACHE_LIMIT_MB" ] && declare PAGECACHE_LIMIT_NEW="$OVERRIDE_PAGECACHE_LIMIT_MB"
        save_value vm.pagecache_limit_mb "$PAGECACHE_LIMIT"
        sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT_NEW"
        log "Setting vm.pagecache_limit_mb=$PAGECACHE_LIMIT_NEW"
        # Set ignore_dirty
        save_value vm.pagecache_limit_ignore_dirty $(sysctl -n vm.pagecache_limit_ignore_dirty)
        sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
        log "Setting vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
    else
        # Disable pagecache limit by setting it to 0
        save_value vm.pagecache_limit_mb "$PAGECACHE_LIMIT"
        sysctl -w "vm.pagecache_limit_mb=0"
        log "Disabling vm.pagecache_limit_mb"
    fi

    # SAP note 1984787 - Installation notes
    # Turn on UUIDD
    if ! systemctl is-active uuidd.socket; then
        save_value uuidd 1
        systemctl enable uuidd.socket
        systemctl start uuidd.socket
    fi

    # The following parameters were specified in tuned.conf before 2017-07-25, but are removed from tuned.conf
    # because they are redundant or no formula exists to calculate them automatically:
    # kernel.sched_min_granularity_ns = 10000000
    # kernel.sched_wakeup_granularity_ns = 15000000
    # vm.dirty_ratio = 10
    # vm.dirty_background_ratio = 3
    # vm.swappiness = 10

    return 0
}

stop() {
    # Revert tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    revert_preparation
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
