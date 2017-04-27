#!/bin/bash
# Optimise kernel parameters for running SAP ASE.
# The calculations are based on:
# - Various SAP notes.
# For SAP HANA tuning, please use "sap-hana" profile instead.
# For SAP Netweaver tuning, please use "sap-netweaver" profile instead of this one.

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

    # SAP note 1680803 - best practice
    source /etc/sysconfig/sapnote-1680803
    # set number of requests for block devices (sdX)
    for _dev in `ls -d /sys/block/sd*`; do
        _dev_save=${_dev//\//_}
        _nrreq=`cat $_dev/queue/nr_requests`
        if [ -n "$_nrreq" -a -n "$NRREQ" ]; then
            if [ $_nrreq -ne $NRREQ ]; then
                save_value "$_dev_save" "$_nrreq"
		echo $NRREQ > $_dev/queue/nr_requests
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
            save_limit=$(echo ${limits_line##*[[:space:]]})
            sed -i "/$limits_line/d" /etc/security/limits.conf
        fi
        echo "$sysconf_line" >> /etc/security/limits.conf
        save_value "memlock_$ulimit_type" "$save_limit"
    done

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

    # Restore number of requests for block devices (sdX)
    for _dev in `ls -d /sys/block/sd*`; do
        _dev_save=${_dev//\//_}
        NRREQ=$(restore_value $_dev_save)
        [ "$NRREQ" ] && echo $NRREQ > $_dev/queue/nr_requests
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

    # Restore UUIDD
    UUIDD=$(restore_value uuidd)
    [ "$UUIDD" ] && systemctl disable uuidd.socket && systemctl stop uuidd.socket

    return 0
}

process $@
