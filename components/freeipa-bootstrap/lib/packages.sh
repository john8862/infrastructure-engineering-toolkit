#!/usr/bin/env bash

package_is_installed() {
    local package=$1
    command_exists rpm || return 127
    rpm -q "$package" >/dev/null 2>&1
}

package_install() {
    local package
    local -a requested=()
    local -a missing=()
    local query_rc
    for package in "$@"; do
        requested+=("$package")
        if package_is_installed "$package"; then
            continue
        else
            query_rc=$?
        fi
        if (( query_rc != 1 )); then
            log_error "could not determine package state for '$package' (rpm query exit code $query_rc)"
            return "$query_rc"
        fi
        missing+=("$package")
    done
    if (( ${#missing[@]} == 0 )); then
        log_info "packages already installed; skipping package transaction: ${requested[*]}"
        return 0
    fi
    if is_dry_run || is_check; then
        plan "install packages: ${missing[*]} using $PACKAGE_MANAGER"
        return 0
    fi
    local -a command=("$PACKAGE_MANAGER" -y install "${missing[@]}")
    run_command "${command[@]}" || return $?
    log_info "installed package set: ${missing[*]}"
}

