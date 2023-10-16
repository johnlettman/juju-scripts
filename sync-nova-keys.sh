#!/usr/bin/env bash
# shellcheck disable=SC1045
[[ -z "${DEBUG}" ]] || { 
    set -o xtrace
}

#########################
# Configuration globals #
#########################
declare -r SSH_MODE_AUTHORIZED_KEYS=600
declare -r SSH_MODE_KNOWN_HOSTS=600

##################
# Cached globals #
##################
declare JUJU_STATUS
declare JUJU_NOVA_APPS

#########################
# Command-line features #
#########################
ansi_reset=$'\e[0m'
ansi_bold=$'\e[1m'
ansi_under=$'\e[4m'
ansi_blink=$'\e[5m'
ansi_reverse=$'\e[7m'

fg_black=$'\e[30m'
fg_red=$'\e[31m'
fg_green=$'\e[32m'
fg_brown=$'\e[33m'
fg_blue=$'\e[34m'
fg_purple=$'\e[35m'
fg_cyan=$'\e[36m'
fg_lightgray=$'\e[37m'

hi_black=$'\e[90m'
hi_red=$'\e[91m'
hi_green=$'\e[92m'
hi_brown=$'\e[93m'
hi_blue=$'\e[94m'
hi_purple=$'\e[95m'
hi_cyan=$'\e[96m'
hi_white=$'\e[97m'

function prompt_yn() {
    local prompt
    local default

    # Configure the prompt from the first argument.
    if [[ -z $1 || ${1:?} ]]; then prompt="$1 "; else prompt=""; fi

    # Configure the default choice from the second argument
    default="$(echo "$2" | tr '[:upper:]' '[:lower:]')"

    local yes_case='y|yes'
    local no_case='n|no'
    local yn='y/n'

    case "${default}" in
        y|yes) yes_case='y|yes|""'; yn='Y/n' ;;
        n|no)  no_case='n|no|""';   yn='y/N' ;;
    esac

    eval "
        while true; do
            read -n 1 -r -p '${prompt}[$yn]: ' answer
            echo # insert newline

            case \"\${answer}\" in
                ${yes_case})
                return 0
                break
                ;;
                ${no_case})
                return 1
                break
                ;;
                *)
                echo 'Please answer Y or N.' >&2
                ;;
            esac
        done"
}

function spinner() {
    local -r s='⣾⣽⣻⢿⡿⣟⣯⣷'
    local -r delay=0.05
    local i=0

    echo -n ' '
    while :; do
        printf "\b%s" "${fg_green}${s:i++%${#s}:1}${ansi_reset}"
        sleep "$delay"
    done
}

function clear_spinner() {
    # stop the spinner
    kill -TERM "$1" 2>/dev/null

    # erase the spinner and reset the cursor position
    printf "\b \b"
}

function list() {
    for item in "$@"; do
        echo "${fg_lightgray}•${ansi_reset} ${hi_white}${item}${ansi_reset}"
    done
}

function truncated_list() {
    local max="$1"; shift
    local truncated=()
    local remaining=0

    for item in "$@"; do
        if [[ "${max}" -gt 0 ]]; then
            truncated+=("${item}")
            (( max-- ))
        else
            (( remaining++ ))
        fi
    done

    list "${truncated[@]}"

    if [[ "${remaining}" -gt 0 ]]; then
        echo "${fg_purple}${remaining} items remaining...${ansi_reset}"
    fi
}

function truncate_lines() {
    local input="$1"; shift
    local max="$*"

    local count
    local truncated

    count=$(echo -n "${input}" | wc -l)

    if ((count > max)); then
        truncated="$(echo -n "$input" | head -n "${max}")"
        local remaining=$((count - max))

        echo "${truncated}"
        echo "${fg_purple}${remaining} more lines...${ansi_reset}"
    else
        # when the input does not exceed the max output it
        echo "${input}"
    fi
}

function nanostamp() {
    date '+%s%N'
}

function nanocompms() {
    local start="$1"
    local stop="$2"

    echo "$(( (stop - start) / 1000000 ))"
}

function timing() {
    echo "${fg_blue}$(nanocompms "$1" "$2")ms${ansi_reset}"
}

####################
# Output utilities #
####################
function count_output_text() {
    local text="$1"; shift
    echo "$*" | 
        jq "map(select(.Stdout | test(\"${text}\")) | 1) | length"
}

function summarize_output() {
    local ok_count
    local err_count

    ok_count="$(count_output_text 'ok!' "$*")"
    err_count="$(count_output_text 'err!' "$*")"

    echo -n "${fg_green}${ok_count} ok${ansi_reset}"

    if (( err_count > 0 )); then
        echo -n ", ${fg_red}${err_count} errors!${ansi_reset}"
    fi

    echo
}

########
# Juju #
########
function juju_status() {
    if [[ -z "${JUJU_STATUS}" ]]; then
        JUJU_STATUS="$(juju status --format=json)"
    fi

    echo "${JUJU_STATUS}"
}

function juju_machines() {
    if [[ -z "${JUJU_MACHINES}" ]]; then
        JUJU_MACHINES="$(juju_status | jq --raw-output '.machines | keys[]')"
    fi

    echo "${JUJU_MACHINES}"
}

function get_nova_apps() {
    if [[ -z "${JUJU_NOVA_APPS}" ]]; then
        JUJU_NOVA_APPS="$(juju_status | 
            jq --raw-output '.applications 
                | to_entries
                | map(select(.value.charm == "nova-compute"))[].key')"
    fi

    echo "${JUJU_NOVA_APPS}";
}

function apps_as_list() {
    local IFS=','
    echo "$*"
}

#############
# OpenStack #
#############
function get_nova_hosts() {
    openstack compute service list --service nova-compute -cHost -fvalue
}

############
# Machines #
############
function get_app_machines() {
    local -a apps=("$@")

    for app in "${apps[@]}"; do
        juju_status |
            jq --raw-output ".applications.\"${app}\".units[].machine"
    done
}

function get_machine_ips() {
    local -a machines=("$@")
    local -A valid_machines
    local machine_selection=""

    # preload an associative array with valid machines to improve the
    # performance of the upcoming loop
    while read -r machine; do
        valid_machines["${machine}"]=1
    done < <(juju_machines)

    # build jq selection string for all machines
    # if they are valid machines
    for machine in "${machines[@]}"; do
        if [[ -n ${valid_machines["${machine}"]} ]]; then
            machine_selection="${machine_selection} .\"${machine}\","
        fi
    done

    # remove trailing comma
    machine_selection="${machine_selection%,}"

    # query all interface IP addresses from each selected machine
    juju_status | 
        jq --raw-output ".machines
            | ${machine_selection} 
            | .\"network-interfaces\"? 
            | select(.!=null) 
            | .. 
            | .\"ip-addresses\"? 
            | select(.!=null)[]"
}

function get_app_ips() {
    local -a machines
    mapfile -t machines < <(get_app_machines "$@")

    get_machine_ips "${machines[@]}"
}

function keyscan() {
    ssh-keyscan "$@" 2>/dev/null
}

###################
# SSH Public Keys #
###################
function get_app_pubkeys() {
    local user="$1"; shift
    local apps_list

    # convert the apps array into a comma-separated list
    apps_list="$(apps_as_list "$@")"

    juju run -a "${apps_list}" "cat ~${user}/.ssh/*.pub" | 
        sort -k3 | 
        grep -Eo 'ssh-(ed2219|ecdsa|rsa|dsa|dss) .*'
}

function save_app_pubkeys() {
    local user="$1"; shift
    local pubkeys="$1"; shift
    local pubkeys_base64
    local apps_list

    # convert the apps array into a comma-separated list
    apps_list="$(apps_as_list "$@")"

    # base64 encode for portability
    pubkeys_base64="$(echo "${pubkeys}" | base64 -w0)"

    juju run --format=json -a "${apps_list}" "
        (
            echo '${pubkeys_base64}' | 
                base64 -d > ~${user}/.ssh/authorized_keys;
            chown '${user}' ~${user}/.ssh/authorized_keys;
            chmod '${SSH_MODE_AUTHORIZED_KEYS}' ~${user}/.ssh/authorized_keys;
            echo 'ok!';
        ) || echo 'err!'"
}

function save_app_keyscan() {
    local user="$1"; shift
    local keyscan="$1"; shift
    local keyscan_base64
    local apps_list

    # convert the apps array into a comma-separated list
    apps_list="$(apps_as_list "$@")"

    # base64 encode for portability
    keyscan_base64="$(echo "${keyscan}" | base64 -w0)"

    local keyscan_script="
        (
            echo '${keyscan_base64}' |
                base64 -d > ~${user}/.ssh/known_hosts;
            chown '${user}' ~${user}/.ssh/known_hosts;
            chmod '${SSH_MODE_KNOWN_HOSTS}' ~${user}/.ssh/known_hosts;
            echo 'ok!';
        ) || echo 'err!'"

    juju run --format=json -a "${apps_list}" "${keyscan_script}"
}


function main() {
    # function timing variables
    local start stop

    # spinner variables
    local spid  # spinner PID

    # display variables
    local max_address_lines=10
    local max_key_lines=5

    # inventory variables
    local -a nova_apps
    local -a nova_ips
    local -a nova_hosts
    local -a nova_addresses
    local root_pubkeys
    local nova_pubkeys
    local host_pubkeys

    #
    # Inventory Collection
    #
    echo "${ansi_bold}${ansi_under}Inventory Collection${ansi_reset}"

    echo -n "${ansi_bold}Pre-loading \`juju status\`${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    juju_status >/dev/null 2>&1
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"

    # nova-compute Applications
    echo -n "${ansi_bold}Detecting nova-compute apps${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    mapfile -t nova_apps < <(get_nova_apps)
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"
    list "${nova_apps[@]}"; echo

    # Nova hostnames
    echo -n "${ansi_bold}Detecting Nova hosts${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    mapfile -t nova_hosts < <(get_nova_hosts)
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"
    truncated_list "${max_address_lines}" "${nova_hosts[@]}"; echo

    # nova-compute IP addresses
    echo -n "${ansi_bold}Detecting Nova IP addresses${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    mapfile -t nova_ips < <(get_app_ips "${nova_apps[@]}")
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"
    truncated_list "${max_address_lines}" "${nova_ips[@]}"; echo

    # Combined nova-compute IP addresses and hostnames
    nova_addresses=("${nova_hosts[@]}" "${nova_ips[@]}")

    # Host SSH public keys 
    echo -n "${ansi_bold}Loading host SSH public keys${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    host_pubkeys="$(keyscan "${nova_addresses[@]}")"
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"
    echo -e "$(truncate_lines "${host_pubkeys}" "${max_key_lines}")\n"

    # SSH public keys for root
    echo -n "${ansi_bold}Loading root user SSH public keys${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    root_pubkeys="$(get_app_pubkeys 'root' "${nova_apps[@]}")"
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"
    echo -e "$(truncate_lines "${root_pubkeys}" "${max_key_lines}")\n"
    
    # SSH public keys for nova
    echo -n "${ansi_bold}Loading nova user SSH public keys${ansi_reset} "
    spinner &
    spid="$!"
    start="$(nanostamp)"
    nova_pubkeys="$(get_app_pubkeys 'nova' "${nova_apps[@]}")"
    stop="$(nanostamp)"
    clear_spinner "${spid}"
    timing "${start}" "${stop}"
    echo -e "$(truncate_lines "${nova_pubkeys}" "${max_key_lines}")\n"

    #
    # Full inventory output option
    #
    if prompt_yn 'Would you like to see the full inventory output?' 'n'; then
        echo "${ansi_bold}Nova hosts${ansi_reset}"
        list "${nova_hosts[@]}"; echo

        echo "${ansi_bold}Nova IP addresses${ansi_reset}"
        list "${nova_ips[@]}"; echo

        echo "${ansi_bold}Host SSH public keys${ansi_reset}"
        echo "${host_pubkeys}"; echo

        echo "${ansi_bold}root user SSH public keys${ansi_reset}"
        echo "${root_pubkeys}"; echo

        echo "${ansi_bold}nova user SSH public keys${ansi_reset}"
        echo "${nova_pubkeys}"; echo
    fi

    #
    # Save process
    #
    prompt_yn 'Would you like to proceed?' 'y' || exit 1

    prompt_yn 'Save host SSH public keys for the root user?' 'y' && {
        keyscan_result="$(save_app_keyscan 'root' "${host_pubkeys}" "${nova_apps[@]}")"
        summarize_output "${keyscan_result}"
    }

    prompt_yn 'Save host SSH public keys for the nova user?' 'y' && {
        keyscan_result="$(save_app_keyscan 'nova' "${host_pubkeys}" "${nova_apps[@]}")"
        summarize_output "${keyscan_result}"
    }

    prompt_yn 'Save root user SSH public keys?' 'y' && {
        root_pubkeys_result="$(save_app_pubkeys 'root' "${root_pubkeys}" "${nova_apps[@]}")"
        summarize_output "${root_pubkeys_result}"
    }

    prompt_yn 'Save nova user SSH public keys?' 'y' && {
        nova_pubkeys_result="$(save_app_pubkeys 'nova' "${nova_pubkeys}" "${nova_apps[@]}")"
        summarize_output "${nova_pubkeys_result}"
    }
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi


