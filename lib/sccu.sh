#!/usr/bin/env bash

# shellcheck disable=SC1004

# sapconf comment update script
# sccu.sh is called by post script of sapconf package installation to 
# update the comment sections in the /etc/sysconfig/sapconf file
# which is impossible by using /bin/fillup

SCCU1=false
SN=/etc/sysconfig/sapconf
SNS=/var/adm/fillup-templates/sysconfig.sapconf
if [ ! -f "$SNS" ]; then
    SNS=/usr/share/fillup-templates/sysconfig.sapconf
    if [ ! -f "$SNS" ]; then
        echo "could not find 'fillup-templates/sysconfig.sapconf' file. Somethings going wrong with the installation."
        exit 1
    fi
fi

if grep "^# SCCU1$" $SN >/dev/null 2>&1; then
    SCCU1=true
fi

if ! (grep "^## SCCU2$" $SN >/dev/null 2>&1); then
    # remove no longer needed 'documentation purpose' comment section from
    # sysconfig file
    if grep "The following lines are only for documentation purpose" "$SN" >/dev/null 2>&1; then
        sed -i "/^####.*##$/,/SAPCONF_END.*/d" "$SN"
    fi
    sed -i "/^# SCCU1$/,/SAPCONF_END.*/d" $SN

    # adjust comments, not covered by fillup
    if grep "## integration of sapconf." "$SN" >/dev/null 2>&1; then
            sed -n "/## Path:.*Other.*/,/## SCCU2/p" "$SNS" > /etc/sysconfig/sapconf.new.$$
            sed "/## Path:.*Other.*/,/## integration of sapconf./d" "$SN" >> /etc/sysconfig/sapconf.new.$$
            mv /etc/sysconfig/sapconf.new.$$ "$SN" || :
    fi
    if grep "switching off tuned," "$SN" >/dev/null 2>&1; then
        sed -i '/switching off tuned,/i\
# Note: when changing the sapconf profile or switching off (stopping) sapconf,\
# both values will be set back to their previous settings.' "$SN"
        sed -i '/switching off tuned,/,+1d' "$SN"
    fi
    sed -i '/, not on Power ppc64 (SAP note 2055470)/d' "$SN"
else
    echo "comments in '$SN' up to date, nothing to change"
    exit 0
fi

# change comments as requested in bsc#1096496
if ! $SCCU1; then
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
fi

# change commented variables so that fillup will preserve the trailing comments
sed -i 's/\(^#.*\)=""$/\1 = ""/' $SN
