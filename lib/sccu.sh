#!/usr/bin/env bash

# shellcheck disable=SC1004

# sapconf comment update script
# sccu.sh is called by post script of sapconf package installation to 
# update the comment sections in the /etc/sysconfig/sapconf file
# which is impossible by using /bin/fillup

SN=/etc/sysconfig/sapconf
# change commented variables so that fillup will preserve the trailing comments
sed -i 's/\(^#.*\)=""$/\1 = ""/' $SN

# change comments as requested in bsc#1096496
if ! (grep "^# SCCU1$" $SN >/dev/null 2>&1); then
    sed -i '/^# SAP Note$/{N;d}' $SN
    sed -i 's/SAP Note 1275776,/SAP Note 1980196,/' $SN
    sed -i 's/SAP Note 1275776/SAP Note 1984787/' $SN
    sed -i 's/SAP Note 1310037/SAP Note 1984787/' $SN
    sed -i 's/ (see bsc#874778)//' $SN
    sed -i 's/ bsc#874778,//' $SN
    sed -i 's/^# TID_7010287$/# SAP Note 1984787, SAP Note 1557506/' $SN
    if ! (grep "^# SAP Note 2382421$" $SN >/dev/null 2>&1); then
        sed -i '/^# set net.ipv4.tcp_slow_start_after_idle=0/a\
#\
# SAP Note 2382421\
#' $SN
    fi
    sed -i '/^# scheduler.$/a\
#\
# SAP Note 1984787' $SN
    sed -i '/^#min_perf_pct = 100$/i\
# SAP Note 2205917\
#' $SN
    sed -i '/^#SAPCONF_END/i\
# SCCU1' $SN
fi

# additonal changed comments as requested in bsc#1096498
if ! (grep "^# SCCU1-15$" $SN >/dev/null 2>&1); then
    sed -i 's/, SAP Note 1557506$//' $SN
    sed -i 's/2205917/2684254/' $SN
    sed -i 's/1984787/2578899/' $SN
    sed -i 's/may be sap-hana or sap-netweaver/is sapconf/' $SN
    sed -i '/^#SAPCONF_END/i\
# SCCU1-15' $SN
fi
