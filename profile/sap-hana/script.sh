#!/bin/bash
# Optimise kernel parameters for running SAP HANA and HANA based products (such as Business One).
# The calculations are based on:
# - Parameters tuned by SAP installation wizard and configure_HANA.sh.
# - Various SAP notes.
# For SAP Netweaver tuning, please use "sap-netweaver" profile instead of this one.
# Authors: Howard Guo <hguo@suse.com>

. /usr/lib/sapconf/common.sh

start() {
    # Apply tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    tune_preparation
    # Read system memory size in MB
    declare -r MEMSIZE=$( math "$(grep MemTotal /proc/meminfo | awk '{print $2}')/1024/1024" )
    # Determine an appropriate value for kernel.shmmni
    declare SHMMNI=$(sysctl -n kernel.shmmni)
    if [ $( math_test "$MEMSIZE < 64" ) ]; then
        declare SHMMNI_NEW=4096
    elif [ $( math_test "$MEMSIZE < 256" ) ]; then
        declare SHMMNI_NEW=65536
    else
        declare SHMMNI_NEW=524288
    fi
    # New SHMMNI may not be lower than current settings
    if [ $( math_test "$SHMMNI_NEW < $SHMMNI" ) ]; then
        declare SHMMNI_NEW="$SHMMNI"
    fi

    # Apply new SHMMNI value
    save_value kernel.shmmni "$SHMMNI"
    sysctl -w "kernel.shmmni=$SHMMNI_NEW"

    # SAP note 1557506 - Linux paging improvements
    source /etc/sysconfig/sapnote-1557506
    declare -r PAGECACHE_LIMIT=$(sysctl -n vm.pagecache_limit_mb)
    if [ "$ENABLE_PAGECACHE_LIMIT" = "yes" ]; then
        # Set pagecache limit = 2% of system memory
        declare PAGECACHE_LIMIT_NEW=$( math "$MEMSIZE*1024*2/100" )
        # If override is present, use the override value.
        [ "$OVERRIDE_PAGECACHE_LIMIT_MB" ] && declare PAGECACHE_LIMIT_NEW="$OVERRIDE_PAGECACHE_LIMIT_MB"
        save_value vm.pagecache_limit_mb "$PAGECACHE_LIMIT"
        sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT_NEW"
        # Set ignore_dirty
        save_value vm.pagecache_limit_ignore_dirty "$(sysctl -n vm.pagecache_limit_ignore_dirty)"
        sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
    else
        # Disable pagecache limit by setting it to 0
        save_value vm.pagecache_limit_mb "$PAGECACHE_LIMIT"
        sysctl -w "vm.pagecache_limit_mb=0"
    fi

    # SAP note 2205917 - KSM and AutoNUMA both should be off
    save_value ksm "$(cat /sys/kernel/mm/ksm/run)"
    echo 0 > /sys/kernel/mm/ksm/run
    save_value numa_balancing "$(cat /proc/sys/kernel/numa_balancing)"
    echo 0 > /proc/sys/kernel/numa_balancing

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
    # Revert tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    revert_preparation

    SHMMNI=$(restore_value kernel.shmmni)
    [ "$SHMMNI" ] && sysctl -w "kernel.shmmni=$SHMMNI"

    # Restore pagecache limit settings
    PAGECACHE_LIMIT=$(restore_value vm.pagecache_limit_mb)
    [ "$PAGECACHE_LIMIT" ] && sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT"
    PAGECACHE_LIMIT_IGNORE_DIRTY=$(restore_value vm.pagecache_limit_ignore_dirty)
    [ "$PAGECACHE_LIMIT_IGNORE_DIRTY" ] && sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"

    # Restore KSM and AutoNUMA settings
    KSM=$(restore_value ksm)
    [ "$KSM" ] && echo "$KSM" > /sys/kernel/mm/ksm/run
    NUMA_BALANCING=$(restore_value numa_balancing)
    [ "$NUMA_BALANCING" ] && echo "$NUMA_BALANCING" > /proc/sys/kernel/numa_balancing

    # Restore UUIDD
    UUIDD=$(restore_value uuidd)
    [ "$UUIDD" ] && systemctl disable uuidd.socket && systemctl stop uuidd.socket

    return 0
}

process $@
