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

function main() {
    local -a juju_models
    local -a juju_machines
    mapfile -t juju_models < <(get_juju_models)

    # configure scratch location for recording errors from SSH sessions
    # setup trap to remove the scratch location when the function returns
    local err_scratch
    err_scratch="$(get_scratch_file)"
    trap '
        info "removing scratch file: ${err_scratch}"; 
        rm "${err_scratch}";
        trap - RETURN;
    ' RETURN

    for model in "${juju_models[@]}"; do
        info_header "In model ${model}"
        mapfile -t juju_machines < <(get_juju_model_machines "${model}")

        for machine in "${juju_machines[@]}"; do
            info_important "model ${model} machine ${machine}"
            if ! juju_ssh "${model}" "${machine}" '
                echo "(all values should be 0)";
                echo -n "runtime: ";
                sysctl kernel.unprivileged_userns_clone;
                echo -n "reboot: ";
                grep \
                    -qsE '''kernel\.unprivileged_userns_clone[[:space:]]*=[[:space:]]*0''' \
                    /etc/sysctl.d/* ; echo $?
            ' 2>"${err_scratch}"; then
                err 'failed to access machine'
                log "$(cat "${err_scratch}")"
            fi
        done
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
