#!/usr/bin/env bash
# Helpers shared by install.sh and the RTMO scripts. Meant to be sourced.

if [ -t 2 ]; then C_RED=$'\033[0;31m' C_YEL=$'\033[0;33m' C_GRN=$'\033[0;32m' C_OFF=$'\033[0m'
else C_RED="" C_YEL="" C_GRN="" C_OFF=""; fi

info() { echo "[info] $*" >&2; }
ok()   { echo "${C_GRN}[ ok ]${C_OFF} $*" >&2; }
warn() { echo "${C_YEL}[warn]${C_OFF} $*" >&2; }
die()  { echo "${C_RED}[fail]${C_OFF} $*" >&2; exit 1; }

# need_cmd <command> <how to install it>
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is missing. Install it: $2"
}

# ask_choice <question> <option>...: print the chosen option on stdout (the question goes to stderr)
ask_choice() {
    local question="$1" answer i
    shift
    echo "$question" >&2
    for ((i = 1; i <= $#; i++)); do echo "  $i) ${!i}" >&2; done
    while true; do
        printf 'Choose [1-%d]: ' "$#" >&2
        read -r answer || die "no answer from the terminal"
        if [[ "$answer" =~ ^[1-9][0-9]?$ ]] && [ "$answer" -le "$#" ]; then
            echo "${!answer}"
            return 0
        fi
        warn "'$answer' is not a valid choice"
    done
}

# ask_yes_no <question> <default: y|n>: return 0 for yes, 1 for no
ask_yes_no() {
    local question="$1" default="$2" hint="[y/N]" answer
    if [ "$default" = "y" ]; then hint="[Y/n]"; fi
    while true; do
        printf '%s %s: ' "$question" "$hint" >&2
        read -r answer || die "no answer from the terminal"
        case "${answer:-$default}" in
            y|Y|yes|Yes) return 0 ;;
            n|N|no|No) return 1 ;;
            *) warn "please answer y or n" ;;
        esac
    done
}

# rtmo_version <repo root>: content of VERSION
rtmo_version() { tr -d '[:space:]' < "$1/VERSION"; }

# rtmo_commit <repo root>: git describe of the checkout (empty outside git)
rtmo_commit() { git -C "$1" describe --tags --always --dirty 2>/dev/null || true; }
