#!/usr/bin/env bash

# util.sh provides utility functions to assist in calculating and applying tuned parameters

# math invokes arbitrary precision calculator "bc" to work on a formula, and then returns the result.
math() {
    echo $* | bc | tr -d '\n'
}

# math_test invokes arbitrary precision calculator "bc" to work on a math comparison formula.
# Returns "1" if formula evaluates to true, otherwise it returns an empty string.
math_test() {
    [ $(echo $* | bc | tr -d '\n') = '1' ] && echo -n 1
}

# log prints a log message into standard output and appends it to /var/log/sapconf.
log() {
    declare -r msg=$(echo $(date --rfc-3339=seconds) ' ' $*)
    # Give log message to standard error so that:
    # it enjoys unbuffered output;
    # a function that uses "echo" to make return value will not be affected by log output
    echo "$msg" > 2
    echo "$msg" >> /var/log/sapconf
}

# increase_sysctl gives sysctl parameter $1 a new value $2 only if it is not lower than the current value.
# The value comparison and new settings are logged.
# The present value (after optimisation) is returned.
increase_sysctl() {
    declare -r param=$1
    declare -r new_val=$2
    declare -r current_val=$(sysctl -n "$param")
    if [ $(math_test "$current_val < $new_val") ]; then
        log "Increasing $param from $current_val to $new_val"
        sysctl -w "$param=$new_val"
        echo -n "$new_val"
    else
        log "Leaving $param unchanged at $current_val instead of calculated $new_val"
        echo -n "$current_val"
    fi
}

# increase_val returns the higher value among $2 (presumably current value) and $3 (future value),
# and log the higher value along with a remark $1.
increase_val() {
    declare -r remark=$1
    declare -r current_val=$2
    declare -r new_val=$3
    if [ $(math_test "$current_val < $new_val") ]; then
        log "Increasing $remark from $current_val to $new_val"
        echo -n "$new_val"
    else
        log "Leaving $remark unchanged at $current_val instead of $new_val"
        echo -n "$current_val"
    fi
}