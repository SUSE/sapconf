#!/usr/bin/env bash

# adapt new SAP Note value by changing /etc/sysconfig/sapconf entries

# adapt2newSNvalues.sh is called by post script of sapconf package installation
# to adapt new SAP Note values

# SAP Note 1771258 - rev. 6 from 05.11.2021
# change values from 65536 to 1048576
# only change, if there are NO customer changes done
change_nofile_limits() {
OVAL="65536"
NVAL="1048576"
for ulimit_group in @sapsys @sdba @dba; do
    for ulimit_type in soft hard; do
        limits_line=$(grep -E "^LIMIT_[1-6]=.*${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile[[:space:]]+${OVAL}" "$SN")
        if [ -n "$limits_line" ]; then
            NLINE="${limits_line//$OVAL/$NVAL}"
            if [[ -n "$NLINE" && "$NLINE" != "$limits_line" ]]; then
                echo "Updating $SN with new SAP Note value '$NVAL' for existing entry '$limits_line'..."
                sed -i "s/$limits_line/$NLINE/" "$SN"
            fi
        fi
    done
done
}

SN=/etc/sysconfig/sapconf
change_nofile_limits
