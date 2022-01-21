#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091

# util.sh provides utility functions to assist in calculating and applying sapconf tuning parameters

STORE=/var/lib/sapconf/saved_state
STORE_SUFFIX=".save"

[ ! -d "$STORE" ] && mkdir -p "$STORE"

# math invokes arbitrary precision calculator "bc" to work on a formula, and then returns the result.
math() {
    echo "$@" | bc | tr -d '\n'
}

# math_test invokes arbitrary precision calculator "bc" to work on a math comparison formula.
# Returns "1" if formula evaluates to true, otherwise it returns an empty string.
math_test() {
    [ "$(echo "$@" | bc | tr -d '\n')" = '1' ] && echo -n 1
}

# log prints a log message into standard output and appends it to /var/log/sapconf.
log() {
    declare msg
    msg="$(date --rfc-3339=seconds)   $*"
    # Give log message to standard error so that:
    # it enjoys unbuffered output;
    # a function that uses "echo" to make return value will not be affected by log output
    echo "$msg" 1>&2
    echo "$msg" >> /var/log/sapconf.log
}

# increase_sysctl gives sysctl parameter $1 a new value $2 only if it is not lower than the current value.
# The value comparison and new settings are logged.
# The present value (after optimisation) is returned.
increase_sysctl() {
    declare -r param=$1
    declare -r new_val=$2
    cur_val=$(sysctl -n "$param")
    declare -r current_val=$cur_val
    if [ "$(math_test "$current_val < $new_val")" ]; then
        log "Increasing $param from $current_val to $new_val"
        sysctl -q -w "$param=$new_val"
        echo -n "$new_val"
    else
        if [ "$(math_test "$current_val > $new_val")" ]; then
            log "Leaving $param unchanged at $current_val instead of calculated $new_val"
        else
            log "Leaving $param unchanged at $current_val"
        fi
        echo -n "$current_val"
    fi
}

# increase_val returns the higher value among $2 (presumably current value) and $3 (future value),
# and log the higher value along with a remark $1.
increase_val() {
    declare -r remark=$1
    declare -r current_val=$2
    declare -r new_val=$3
    if [ "$(math_test "$current_val < $new_val")" ]; then
        log "Increasing $remark from $current_val to $new_val"
        echo -n "$new_val"
    else
        if [ "$(math_test "$current_val > $new_val")" ]; then
            log "Leaving $remark unchanged at $current_val instead of $new_val"
        else
            log "Leaving $remark unchanged at $current_val"
        fi
        echo -n "$current_val"
    fi
}

# check, if a value is defined in the (sourced) sysconfig file
# if not, log a warning and use a pre-defined default value
chk_conf_val() {
    declare -r val2chk=$1
    declare -r def_val=$2
    val2set=${!val2chk}
    if [ -z "$val2set" ]; then
        log "ATTENTION: $val2chk not set in sysconfig file."
        echo -n "$def_val"
    else
        echo -n "$val2set"
    fi
}

# check, if a value is defined in the (sourced) sysconfig file
# if not, log a warning and leave the current system value unchanged
# otherwise set the value from sysconfig file as the new system value
chk_and_set_conf_val() {
    declare -r val2chk=$1
    declare -r param=$2
    val2set=${!val2chk}
    current_val=$(sysctl -n "$param")
    if [ -z "$val2set" ]; then
        log "ATTENTION: $val2chk not set in sysconfig file."
        log "Leaving $param unchanged at $current_val"
    else
        if [ "$(math_test "$current_val < $val2set")" ]; then
            log "Increasing $param from $current_val to $val2set"
            sysctl -q -w "$param=$val2set"
        elif [ "$(math_test "$current_val > $val2set")" ]; then
            log "Decreasing $param from $current_val to $val2set"
            sysctl -q -w "$param=$val2set"
        else
            log "Leaving $param unchanged at $current_val"
        fi
    fi
}

# for parameters defined in /sys or /proc fs
# check, if a value is defined in the (sourced) sysconfig file
# if not, log a warning and leave the current system value unchanged
# otherwise save the old value and set the value from sysconfig file
# as the new system value
#
# save_and_set_sys_val param sysfile
# example:
# save_and_set_sys_val ksm /sys/kernel/mm/ksm/run
#
# param is the parameter name in the /sys or /proc fs and is used as
# filename to store the old state
# it's in lowercase letter, with uppercase letters it's the parameter
# found in the sysconfig file of sapconf
#
# sysfile is the name of the file in the /sys or /proc fs
#
# example:
# param=ksm, sysfile=/sys/kernel/mm/ksm/run, and KSM in sysconfig
save_and_set_sys_val() {
    declare -r param=$1
    declare -r sysfile=$2

    [[ ! -f $sysfile ]] && log "Can't set parameter $param, because file $sysfile does not exist." && return 0
    current_val=$(cat "$sysfile")
    new_val=$(chk_conf_val "${param^^}" "$current_val")
    if [ "$current_val" != "$new_val" ]; then
        save_value "$param" "$current_val"
        log "Change $param from $current_val to $new_val"
        echo "$new_val" > "$sysfile"
    else
        log "Leaving $param unchanged at $current_val"
    fi
}

# source config file from /etc/sysconfig
source_sysconfig() {
    declare cfgfile=$1
    # remove blanks from the variable declaration to prevent errors
    if sed -i '/^[^#].*[[:blank:]][[:blank:]]*=[[:blank:]][[:blank:]]*.*/s%[[:blank:]]%%g' "$cfgfile" >/dev/null 2>&1; then
        source "$cfgfile"
    else
        # use a temporary file for /etc/sysconfig/sapconf to avoid problems
        # with read only /etc filesystem of FlexFrame
        TMPSAPCONF=$(mktemp /tmp/sapconf_$$.XXXX)

        sed '/^[^#].*[[:blank:]][[:blank:]]*=[[:blank:]][[:blank:]]*.*/s%[[:blank:]]%%g' "$cfgfile" > "$TMPSAPCONF"
        source "$TMPSAPCONF"
        rm -f "$TMPSAPCONF"
    fi
}

# Save value
# $0 parameter_name value
save_value() {
    echo "$2" > "$STORE/${1}$STORE_SUFFIX"
}

# Restore value from store
# $0 parameter_name
restore_value() {
    [ -r "$STORE/${1}$STORE_SUFFIX" ] && res_val=$(cat "$STORE/${1}$STORE_SUFFIX")
    rm -f "$STORE/${1}$STORE_SUFFIX" >/dev/null 2>&1
    echo "$res_val"
}

# get active sysfs value
# $0 sysfs_filename
get_sys_val() {
        [ -f "$1" ] && sed 's/.*\[\(.*\)\].*/\1/' "$1"
}

# set block device read_ahead
set_readahead() {
    if [ -z "$READAHEAD" ]; then
        log "ATTENTION: 'READAHEAD' not set in sysconfig file."
        log "Leaving block device read_ahead_kb settings unchanged"
        return 0
    fi
    # read block devices from /sys/block
    for i in /sys/block/*; do
        dev=${i##*/}
        # read current read_ahead_kb value from /sys/block/*/queue/read_ahead_kb
	[ -f /sys/block/"$dev"/queue/read_ahead_kb ] && cur_val=$(get_sys_val /sys/block/"$dev"/queue/read_ahead_kb)
        if [ "$cur_val" != "$READAHEAD" ]; then
            [ -n "$cur_val" ] && save_value READ_AHEAD_"$dev" "$cur_val"
            log "Change value of read_ahead_kb for block device '/sys/block/$dev' from '$cur_val' to '$READAHEAD'"
            echo "$READAHEAD" > /sys/block/"$dev"/queue/read_ahead_kb
        else
            log "Leaving read_ahead_kb for block device '/sys/block/$dev' unchanged at '$cur_val'"
        fi
    done
}

# restore saved values for block device read_ahead
restore_readahead() {
    # read block devices from /sys/block
    for i in /sys/block/*; do
        dev=${i##*/}
        old_rah=$(restore_value READ_AHEAD_"$dev")
        [ -n "$old_rah" ] && log "Restoring read_ahead_kb '$old_rah' for block device '/sys/block/$dev'" && echo "$old_rah" > /sys/block/"$dev"/queue/read_ahead_kb
    done
}

# check for valid scheduler setting in parameter IO_SCHEDULER
is_valid_scheduler() {
    bdev=$1
    avail_scheds=$(sed -e 's|\[||g' -e 's|\]||g' /sys/block/"$bdev"/queue/scheduler)
    for sched in $IO_SCHEDULER; do
        for s in $avail_scheds; do
            if [ "$sched" == "$s" ]; then
                log "using '$sched' as new scheduler for block device '/sys/block/$bdev'."
                echo "$sched"
                return 0
            fi
        done
        log "'$sched' is not a valid scheduler for block device '/sys/block/$bdev', skipping."
    done
    # no valid scheduler found in config file
    return 1
}

# get the valid block devices for setting the scheduler
get_valid_block_devices() {
    # read block devices from /sys/block
    candidates=()
    excludedevs=()
    for i in /sys/block/*; do
        skip=false
        dev=${i##*/}
        if [ -f /sys/block/"$dev"/dm/uuid ]; then
            if grep '^mpath-' /sys/block/"$dev"/dm/uuid >/dev/null 2>&1; then
                candidates+=("$dev")
                for s in /sys/block/"$dev"/slaves/*; do
                    excludedevs+=("${s##*/}")
                done
            else
                dm=$(sed 's/\(.*\)-.*/\1/' /sys/block/"$dev"/dm/uuid)
                log "skipping device '$dev'($dm), not applicable"
            fi
        else
            # check block device type.
            if [ ! -f /sys/block/"$dev"/device/type ]; then
                skip=true
            elif [[ $(cat /sys/block/"$dev"/device/type) -ne 0 ]]; then
                skip=true
            fi
            # virtio block devices (vd* and xvd*) and NVME devices do not have
            # a 'type' file, need workaround
            [[ "$dev" =~ ^x?vd* || "$dev" =~ ^nvme[0-9]+n[0-9]+$ ]] && skip=false
            if $skip; then
                log "skipping device '$dev', not applicable"
                continue
            fi
            candidates+=("$dev")
        fi
    done
    for bdev in "${candidates[@]}"; do
        exclude=false
        for edev in "${excludedevs[@]}"; do
            if [ "$bdev" == "$edev" ]; then
                log "skipping device '$bdev', not applicable for dm slaves"
                exclude=true
                break
            fi
        done
        ! $exclude && disklist="$disklist $bdev"
    done
    echo "$disklist"
}

# set block device scheduler
set_scheduler() {
    if [ -z "$IO_SCHEDULER" ]; then
        log "ATTENTION: 'IO_SCHEDULER' not set in sysconfig file."
        log "Leaving block device scheduler settings unchanged"
        return 0
    fi
    for dev in $(get_valid_block_devices); do
        # check, if IO_SCHEDULER includes a valid scheduler
        # use the first valid scheduler as new scheduler
        if ! new_sched=$(is_valid_scheduler "$dev"); then
            log "sysconfig file does not contain a valid scheduler for block device '/sys/block/$dev'"
            continue
        fi
        # read current scheduler value from /sys/block/*/queue/scheduler
        #[[ -f /sys/block/"$dev"/queue/scheduler ]] && cur_val=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/block/"$dev"/queue/scheduler)
	[ -f /sys/block/"$dev"/queue/scheduler ] && cur_val=$(get_sys_val /sys/block/"$dev"/queue/scheduler)
        if [ "$cur_val" != "$new_sched" ]; then
            [ -n "$cur_val" ] && save_value IO_SCHEDULER_"$dev" "$cur_val"
            [ -n "$new_sched" ] && log "Change IO scheduler for block device '$dev' from '$cur_val' to '$new_sched'" && echo "$new_sched" > /sys/block/"$dev"/queue/scheduler
        else
            log "Leaving scheduler for block device '/sys/block/$dev' unchanged at '$cur_val'"
        fi
    done
}

# restore saved values for block device scheduler
restore_scheduler() {
    # read block devices from /sys/block
    #for i in $(eval LANG=C ls -1 /sys/block 2>/dev/null); do
    for i in /sys/block/*; do
        dev=${i##*/}
        old_sched=$(restore_value IO_SCHEDULER_"$dev")
        [ -n "$old_sched" ] && log "Restoring scheduler '$old_sched' for block device '/sys/block/$dev'" && echo "$old_sched" > /sys/block/"$dev"/queue/scheduler
    done
}

# configure C-States for lower latency
# adjust latency settings - disable cpu idle states
set_force_latency() {
    [[ $(uname -m) != "x86_64" ]] && log "latency settings are only relevant for Intel-based systems." && return 0

    if [ -z "$FORCE_LATENCY" ]; then
        log "'FORCE_LATENCY' not set in sysconfig file."
        log "Leaving latency settings untouched"
        return 0
    fi

    # read /sys/devices/system/cpu/cpu*
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu="${cpu_path##*/}"
        [[ ! -d $cpu_path/cpuidle ]] && log "idle settings not supported for cpu '$cpu'" && continue
        # /sys/devices/system/cpu/cpu*/cpuidle/state*
        for cstate_path in "$cpu_path"/cpuidle/state*; do
            cstate="${cstate_path##*/}"
            # read /sys/devices/system/cpu/cpu*/cpuidle/state*/disable
            old_state=$(cat "$cstate_path"/disable)
            # save_state filename cpu0_state0.save, cpu0_state1.save, ..
            save_value "${cpu}"_"${cstate}" "$old_state"
            # read /sys/devices/system/cpu/cpu*/cpuidle/state*/latency
            latency=$(cat "$cstate_path"/latency)
            if [ "$latency" -gt "$FORCE_LATENCY" ]; then
                # set new latency states
                log "Disable idle state for cpu '${cpu}' and state '${cstate}'"
                echo 1 > "$cstate_path"/disable
            fi
            if [[ $latency -le $FORCE_LATENCY && $old_state -eq 1 ]]; then
                # reset previous set latency state
                log "Enable idle state for cpu '${cpu}' and state '${cstate}'"
                echo 0 > "$cstate_path"/disable
            fi
        done
    done
}

# restore saved values for latency settings - restore cpu idle states
restore_force_latency() {
    # read /sys/devices/system/cpu/cpu*
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu="${cpu_path##*/}"
        [[ ! -d $cpu_path/cpuidle ]] && log "idle settings not supported for cpu '$cpu'" && continue
        # /sys/devices/system/cpu/cpu*/cpuidle/state*
        for cstate_path in "$cpu_path"/cpuidle/state*; do
            cstate="${cstate_path##*/}"
            # restore from file cpu0_state0.save, cpu0_state1.save, ..
            old_state=$(restore_value "${cpu}"_"${cstate}")
            [ -n "$old_state" ] && log "Restoring idle state '$old_state' for cpu '${cpu}' and state '${cstate}'" && echo "$old_state" > "$cstate_path"/disable
        done
    done
}

# get current energy_perf_bias values of all cpus
get_perf_bias() {
    /usr/bin/cpupower -c all info -b | awk '
        /^analyzing CPU/ {
        cpu_nr=substr($3, 1, length($3)-1)
        getline
        if ( $0 ~ /^perf-bias:/ ) {
            perf=$2
        }
        printf("cpu_%s %s\n", cpu_nr, perf)
    }'
}

# set the energy_perf_bias values of all cpus to the 'PERF_BIAS' value from
# the sysconfig file
set_perf_bias() {
    [[ $(uname -m) != "x86_64" ]] && log "energy_perf_bias settings are only relevant for Intel-based systems." && return 0

    if [ -z "$PERF_BIAS" ]; then
        log "'PERF_BIAS' not set in sysconfig file."
        log "Leaving energy_perf_bias settings untouched"
        return 0
    fi

    case "$PERF_BIAS" in
    "performance")
        PERF_BIAS=0
        ;;
    "normal")
        PERF_BIAS=6
        ;;
    "powersave")
        PERF_BIAS=15
        ;;
    esac
    [[ "$PERF_BIAS" -lt 0 || "$PERF_BIAS" -gt 15 ]] && log "wrong 'PERF_BIAS' setting. Value '$PERF_BIAS' out of scope, leaving energy_perf_bias settings unchanged" && return 0

    [[ ! -x /usr/bin/cpupower ]] && log "command '/usr/bin/cpupower' not found. System does not support Intel's performance bias setting" && return 0
    /usr/bin/cpupower info -b > /tmp/sapconf-cpupower-test
    if grep "System does not support Intel's performance bias setting" /tmp/sapconf-cpupower-test >/dev/null 2>&1; then
        rm -f /tmp/sapconf-cpupower-test
        log "System does not support Intel's performance bias setting"
        return 0
    fi
    rm -f /tmp/sapconf-cpupower-test
    get_perf_bias | while read -r c p; do
        save_value "$c" "$p"
    done
    log "Set energy_perf_bias value for all cpus to '$PERF_BIAS'"
    /usr/bin/cpupower -c all set -b "$PERF_BIAS"
}

# restore the energy_perf_bias setting of all cpus
restore_perf_bias() {
    get_perf_bias | while read -r c p; do
        cpu="${c##cpu_}"
        old_perf_bias=$(restore_value "$c")
        [ -n "$old_perf_bias" ] && log "Restoring energy_perf_bias value '$old_perf_bias' for cpu '${cpu}'" && /usr/bin/cpupower -c "$cpu" set -b "$old_perf_bias"
    done
}

# set the min_perf_pct value to the 'MIN_PERF_PCT' value from
# the sysconfig file
set_min_perf_pct() {
    param=min_perf_pct
    sysfile=/sys/devices/system/cpu/intel_pstate/min_perf_pct
    if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        if [ -z "$MIN_PERF_PCT" ]; then
            log "'MIN_PERF_PCT' not set in sysconfig file."
            log "Leaving min_perf_pct settings untouched"
            return 0
        fi
        [[ ! -f $sysfile ]] && log "Can't set parameter $param, because file $sysfile does not exist." && return 0
        current_val=$(cat "$sysfile")
        if [ "$current_val" != "$MIN_PERF_PCT" ]; then
            save_value "$param" "$current_val"
            log "Change $param from $current_val to $MIN_PERF_PCT"
            echo "$MIN_PERF_PCT" > "$sysfile"
        else
            log "Leaving $param unchanged at $current_val"
        fi
    fi
}

# set cpu scaling governor setting and store the old settings
set_governor() {
    [[ $(uname -m) != "x86_64" ]] && log "scaling governor settings are only relevant for Intel-based systems." && return 0

    if [ -z "$GOVERNOR" ]; then
        log "'GOVERNOR' not set in sysconfig file."
        log "Leaving scaling governor settings untouched"
        return 0
    fi

    [[ ! -x /usr/bin/cpupower ]] && log "command '/usr/bin/cpupower' not found. System does not support Intel's performance setting" && return 0

    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu="${cpu_path##*/}"
        [[ ! -f $cpu_path/cpufreq/scaling_governor ]] && log "cpu '$cpu' does not support a scaling governor. Skipping...." && continue
        if ! grep "$GOVERNOR" "$cpu_path"/cpufreq/scaling_available_governors >/dev/null 2>&1; then
            log "'$GOVERNOR' is not a valid governor for cpu '$cpu', skipping."
            continue
        fi
        # /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        old_gov=$(cat "$cpu_path"/cpufreq/scaling_governor)
        if [ "$old_gov" != "$GOVERNOR" ]; then
            save_value "${cpu}_gov" "$old_gov"
            cpu_nr="${cpu##cpu}"
            log "Set scaling governor for cpu '${cpu}' to '$GOVERNOR'"
            if [ -x /usr/bin/cpupower ]; then
                /usr/bin/cpupower -c "${cpu_nr}" frequency-set -g "$GOVERNOR"
            else
                log "command '/usr/bin/cpupower' not found. Falling back to direct change the file for scaling governor setting"
                echo "$GOVERNOR" > "$cpu_path"/cpufreq/scaling_governor
            fi
        else
            log "Leaving scaling governor for cpu '${cpu}' unchanged at '$old_gov'"
        fi
    done
}

# re-enable previous CPU governor settings
restore_governor() {
    # read /sys/devices/system/cpu/cpu*
    for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu="${cpu_path##*/}"
        cpu_nr="${cpu##cpu}"
        old_gov=$(restore_value "${cpu}_gov")
        [ -n "$old_gov" ] && log "Restoring scaling governor '$old_gov' for cpu '${cpu}'" && /usr/bin/cpupower -c "${cpu_nr}" frequency-set -g "$old_gov"
    done
}

# set performance settings according to SAP Note 2205917
set_performance_settings() {
    # read performance related requirements from the common configuration file
    # sysconfig/sapconf
    if [ -r /etc/sysconfig/sapconf ]; then
        source_sysconfig /etc/sysconfig/sapconf
    else
        log 'Failed to read /etc/sysconfig/sapconf'
        exit 1
    fi

    log "--- Going to apply performance settings"
    # latency settings
    set_force_latency
    # energy_perf_bias settings
    set_perf_bias
    # scaling governor settings
    set_governor
    # min_perf_pct settings
    set_min_perf_pct
    log "--- Finished application of performance settings"
}

# restore previous performance settings
restore_performance_settings() {
    # latency settings
    restore_force_latency
    # energy_perf_bias settings
    restore_perf_bias
    # scaling governor settings
    restore_governor
    # min_perf_pct settings
    if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        MIN_PERF_PCT=$(restore_value min_perf_pct)
        [ "$MIN_PERF_PCT" ] && log "Restoring min_perf_pct=$MIN_PERF_PCT" && echo "$MIN_PERF_PCT" > /sys/devices/system/cpu/intel_pstate/min_perf_pct
    fi
}

# check for active saptune service
# saptune.service is enabled or has exited or save state files are present
# (jsc#SLE-10987 decision)
chk_active_saptune() {
    enabled=false
    active=false
    used=false
    if systemctl -q is-enabled saptune.service 2>/dev/null; then
        enabled=true
        txt="is enabled"
    fi
    if systemctl -q is-active saptune.service 2>/dev/null; then
        active=true
        if [ -n "$txt" ]; then
            txt=$txt" and active"
        else
            txt="is active"
        fi
    fi
    if [[ $(ls -A /var/lib/saptune/saved_state 2>/dev/null) || $(ls -A /run/saptune/saved_state 2>/dev/null) ]]; then
        used=true
        if [ -n "$txt" ]; then
            txt=$txt" and has applied notes/solutions"
        else
            txt="has applied notes/solutions"
        fi
    fi
    if $enabled || $active || $used; then
        log "ATTENTION: saptune $txt, so refuse any action"
        if [ -f /run/sapconf_act_profile ]; then
            cat /run/sapconf_act_profile > /var/lib/sapconf/last_profile
            rm -f /run/sapconf_act_profile
        fi
        return 1
    fi
    return 0
}
