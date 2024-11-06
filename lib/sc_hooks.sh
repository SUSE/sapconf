#!/usr/bin/env bash

# sc_hooks.sh is called by post script of sapconf package installation
# to handle some special cases
# e.g. handle special workaround for bsc#1209408

if [ "$1" == "" ]; then
    echo "ERROR: missing argument"
    exit 1
else
    hook_opt="$1"
fi  
SN=/etc/sysconfig/sapconf

add_ignore() {
    sed -i 's/^IGNORE_RELOAD=.*/IGNORE_RELOAD=yes/' $SN
}

del_ignore() {
    ignore="nothing"
    entry=$(grep '^IGNORE_RELOAD="*yes"*' $SN)
    no_entry=$(grep '^# bsc#1209408' $SN)
    if [ -n "$entry" ] && [ -z "$no_entry" ]; then
       ignore="add"
       sed -i 's/^IGNORE_RELOAD=.*//' $SN
    fi
    echo $ignore
}

lc_add() {
    sed -i 's%^# /etc/security/limits.conf%# /etc/security/limits.d/sapconf-nofile.conf%' "$SN"
    sed -i 's/^# SAP Note 1771258$/# SAP Note 1771258 (rev. 6 from 05.11.2021)/' "$SN"
    sed -i 's/^# Set to 65536/# Set to 1048576 (as recommended by revision 6 of the SAP Note)/' "$SN"
}

thp_reset() {
    osvers=$(grep ^VERSION= /etc/os-release | awk -F \" '{ print $2 }')
    case "$osvers" in
    15-SP[1234])
        sed -i 's/^THP=madvise/THP=never/g' "$SN"
        sed -i "s/^# set to 'madvise'/# set to 'never'/g" "$SN"
        sed -i "/^# 'madvise' will enter.*/,+1d" "$SN"
        sed -i 's/^# Configure transparent hugepages/# Disable transparent hugepages/' "$SN"
        ;;
    esac
}

thp_change() {
    osvers=$(grep ^VERSION= /etc/os-release | awk -F \" '{ print $2 }')
    case "$osvers" in
    15-SP[567])
        sed -i 's/^THP=never/THP=madvise/g' "$SN"
        sed -i "s/^# set to 'never'/# set to 'madvise'/g" "$SN"
        sed -i '/^# Disable transparent hugepages/i\
# '\''madvise'\'' will enter direct reclaim like '\''always'\'' but only for regions that\
# are have used madvise(MADV_HUGEPAGE). This is the default behaviour.' "$SN"
        sed -i 's/^# Disable transparent hugepages/# Configure transparent hugepages/' "$SN"
        ;;
    esac
}

case "$hook_opt" in
add)
    add_ignore
    lc_add
    thp_change
    ;;
del)
    del_ignore
    ;;
nothing)
    lc_add
    thp_change
    ;;
reset)
    thp_reset
    ;;
esac
