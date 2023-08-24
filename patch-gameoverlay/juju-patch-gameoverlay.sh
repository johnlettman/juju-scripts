#!/usr/bin/env bash
declare -i ssh_timeout=10 # seconds

function log() { echo -e "$*" >&2; }
function info() { log '\e[34minfo\e[0m' "$*"; }
function info_header() { log "\n\e[1;30;44m$*\e[0m"; }
function info_important { log '\n\e[34minfo\e[0m' "\e[1;97m$*\e[0m"; }
function err() { log '\e[31merr \e[0m' "$*"; }
function err_header() { log "\n\e[4;37;41m$*\e[0m"; }
function bullet() { echo -en '\xE2\x80\xA2 '; }

function get_juju_models() {
    juju list-models --format=json |
        jq --raw-output '.models[].name'
}

function get_juju_model_machines() {
    local model="${1}"
    juju list-machines --model="${model}" --format=json |
        jq --raw-output '
            .machines | to_entries[] | 
            .key, ((.value.containers // empty) | to_entries[] | .key)'
}

function get_scratch_file() {
    mktemp "${TMPDIR:-/tmp/}$(basename "$0").XXXXXXXXXXXX"
}

function juju_ssh() {
    local model="$1"
    shift
    local machine="$1"
    shift
    local command="$*"

    juju ssh --model="${model}" "${machine}" \
        -oConnectTimeout="${ssh_timeout}" \
        "${command}"

    return $?
}

function patch_runtime() {
    local model="$1"
    local machine="$2"
    local mm="${model}:${machine}"

    # configure scratch location for recording errors from SSH sessions
    # setup trap to remove the scratch location when the function returns
    local err_scratch
    err_scratch="$(get_scratch_file)"
    trap '
        info "[${mm}] removing scratch file: ${err_scratch}"; 
        rm "${err_scratch}";
        trap - RETURN;
    ' RETURN

    # obtain the current runtime value of unprivileged_userns_clone
    local value
    info "[${mm}]" 'getting runtime unprivileged_userns_clone'
    if ! value="$(
        juju_ssh "${model}" "${machine}" \
        'sysctl -n kernel.unprivileged_userns_clone' \
            | tr -d '\r' | tr -d '\n' | tr -d ' ' \
        2>"${err_scratch}"
    )"
    then
        err "[${mm}]" 'failed to obtain current runtime unprivileged_userns_clone'
        log "$(cat "${err_scratch}")"
        return 1
    fi

    info "[${mm}]" "unprivileged_userns_clone = ${value}"

    # when the value is already 0, we don't need to do anything
    if (( value == 0 )); then
        info "[${mm}]" 'no need to patch runtime, skipping'
        return 0
    fi

    # do the actual patch
    info "[${mm}]" 'patching runtime unprivileged_userns_clone'
    if ! \
        juju_ssh "${model}" "${machine}" \
        sudo sysctl -w kernel.unprivileged_userns_clone=0 \
        1>"${err_scratch}" 2>&1
    then
        err "[${mm}]" 'failed to patch runtime unprivileged_userns_clone'
        log "$(cat "${err_scratch}")"
        return 1
    fi
}

function patch_reboot() {
    local model="$1"
    local machine="$2"
    local mm="${model}:${machine}"

    # check whether the reboot patch already exists
    if juju_ssh "${model}" "${machine}" '
        grep \
        -qsE '''kernel\.unprivileged_userns_clone[[:space:]]*=[[:space:]]*0''' \
        /etc/sysctl.d/*
    ' 1>/dev/null 2>&1
    then
        info "[${mm}]" 'reboot patch already exists, skipping'
        return 0
    fi

    # configure scratch location for recording errors from SSH sessions
    # setup trap to remove the scratch location when the function returns
    local err_scratch
    err_scratch="$(get_scratch_file)"
    trap '
        info "[${mm}] removing scratch file: ${err_scratch}"; 
        rm "${err_scratch}";
        trap - RETURN;
    ' RETURN

    # do the actual patch
    info "[${mm}]" 'patching reboot unprivileged_userns_clone'
    if ! juju_ssh "${model}" "${machine}" '
        echo kernel.unprivileged_userns_clone=0 \
            | sudo tee /etc/sysctl.d/99-disable-unpriv-userns.conf
    ' 1>"${err_scratch}" 2>&1
    then
        err "[${mm}]" 'failed to patch reboot unprivileged_userns_clone'
        log "$(cat "${err_scratch}")"
        return 1
    fi
}

function main() {
    local -a juju_models
    local -a juju_machines
    local -a failed_patch_runtime=()
    local -a failed_patch_reboot=()

    local mm
    local failed_message='\e[1;37;41mfailed\e[0m'

    mapfile -t juju_models < <(get_juju_models)
    info 'detected Juju models:' "${juju_models[@]}"

    for model in "${juju_models[@]}"; do
        info_header "In model ${model}"
        info "[${model}] acquiring machines"
        mapfile -t juju_machines < <(get_juju_model_machines "${model}")
        info "[${model}] found machines: ${juju_machines[*]}"

        if ((${#juju_machines[@]} != 0)); then
            for machine in "${juju_machines[@]}"; do
                mm="${model}:${machine}"
                info_important "[${model}] patching machine ${machine}"

                if ! patch_runtime "${model}" "${machine}"; then
                    failed_patch_runtime+=("${model}:${machine}")
                fi

                if ! patch_reboot "${model}" "${machine}"; then
                    failed_patch_reboot+=("${mm}")
                fi
            done
        else
            info '... no machines in this model, skipping'
        fi
    done

    if ((${#failed_patch_runtime[@]} != 0)); then
        err_header 'Machines that failed to patch runtime'
        log '> Consider manually intervening'
        for machine in "${failed_patch_runtime[@]}"; do
            bullet
            log "${machine} ${failed_message}"
        done
    fi

    if ((${#failed_patch_reboot[@]} != 0)); then
        err_header 'Machines that failed to patch reboot'
        log '> Consider manually intervening'
        for machine in "${failed_patch_reboot[@]}"; do
            bullet
            log "${machine} ${failed_message}"
        done
    fi

}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
