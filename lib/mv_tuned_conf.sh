#!/usr/bin/env bash

# move custom specific sapconf related tuned profiles from /etc/tuned/
# to /var/lib/sapconf/saved_configs

# mv_tuned_conf.sh is called by post script of sapconf package installation to 
# move the custom specific values from /etc/tuned/<profil>/tuned.conf to
# the sysconfig files.

[ ! -d /var/lib/sapconf/saved_configs ] && mkdir -p /var/lib/sapconf/saved_configs

CUSTOM_TCONF=""
SN=/etc/sysconfig/sapconf
# check, if the tuned profile directories already availabe in the saved_config
# area. If yes, may be backup/restore has added the already removed directories
# again. So do not process the tuned profile values again to not harm the
# current configuration in /etc/sysconfig/sapconf
for prof in sapconf sap-hana sap-netweaver sap-ase sap-bobj; do
    if [ -d /var/lib/sapconf/saved_configs/$prof ]; then
        echo "copy of profile '$prof' already available in /var/lib/sapconf/saved_configs. So no need to process custom specific tuned profile values again. Skipping ...."
        exit 0
    fi
done

if [ -f /etc/tuned/sapconf/tuned.conf ]; then
    CUSTOM_TCONF=/etc/tuned/sapconf/tuned.conf
fi
if [ -f /etc/tuned/sap-hana/tuned.conf ]; then
    if [ -n "$CUSTOM_TCONF" ]; then
        echo "moving custom profile /etc/tuned/sap-hana to /var/lib/sapconf/saved_configs"
        mv /etc/tuned/sap-hana /var/lib/sapconf/saved_configs
    else
        CUSTOM_TCONF=/etc/tuned/sap-hana/tuned.conf
    fi
fi
if [ -f /etc/tuned/sap-netweaver/tuned.conf ]; then
    if [ -n "$CUSTOM_TCONF" ]; then
        echo "moving custom profile /etc/tuned/sap-netweaver to /var/lib/sapconf/saved_configs"
        mv /etc/tuned/sap-netweaver /var/lib/sapconf/saved_configs
    else
        CUSTOM_TCONF=/etc/tuned/sap-netweaver/tuned.conf
    fi
fi
if [ -f /etc/tuned/sap-ase/tuned.conf ]; then
    echo "moving custom profile /etc/tuned/sap-ase to /var/lib/sapconf/saved_configs"
    mv /etc/tuned/sap-ase /var/lib/sapconf/saved_configs
fi
if [ -f /etc/tuned/sap-bobj/tuned.conf ]; then
    echo "moving custom profile /etc/tuned/sap-bobj to /var/lib/sapconf/saved_configs"
    mv /etc/tuned/sap-bobj /var/lib/sapconf/saved_configs
fi
if [ -n "$CUSTOM_TCONF" ]; then
    # customer specific sapconf tuned config available
    # read sapconf related parameter values and add them to
    # /etc/sysconfig/sapconf, if needed
    # ignore comment lines
    for pat in governor energy_perf_bias min_perf_pct force_latency elevator; do
        if [ "$pat" == energy_perf_bias ]; then
            # rewrite variable name
            TVAR=${pat##energy_}
            NNAME=${TVAR^^}
        elif [ "$pat" == elevator ]; then
            # rewrite variable name
            NNAME=IO_SCHEDULER
        else
            NNAME=${pat^^}
        fi
        TCVAL=$(grep "${pat}[[:blank:]]*=" $CUSTOM_TCONF | grep "^[^#]" | sed "s/ = /=/" | awk -F = '{print $2}')
        NLINE="$NNAME=$TCVAL"
        SCPAT=$(grep "$NNAME=" $SN | grep "^[^#]")
        if [[ "$NNAME" == IO_SCHEDULER && -n "$SCPAT" ]]; then
            if [ -n "$TCVAL" ]; then
                if ! echo "$SCPAT" | sed 's/"//g' | awk -F = '{print $2}' | grep "$TCVAL" >/dev/null 2>&1; then
                    echo "Add scheduler '$TCVAL' from '$CUSTOM_TCONF' to the list of schedulers in '$SN'"
                    NLINE=${SCPAT//IO_SCHEDULER=\"/IO_SCHEDULER=\"$TCVAL }
                else
                    NLINE=$SCPAT
                fi
            fi
        fi
        if [[ -n "$NLINE" && -n "$SCPAT" && "$NLINE" != "$SCPAT" ]]; then
            echo "Updating $SN line '$SCPAT' with line '$NLINE' from $CUSTOM_TCONF..."
            sed -i "s/$SCPAT/$NLINE/" $SN
        fi
    done
    mv "$(dirname $CUSTOM_TCONF)" /var/lib/sapconf/saved_configs
fi
