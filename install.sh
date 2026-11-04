#!/usr/bin/env bash
# ============================================================================
#  install.sh: install RTMO from this checkout (plan section 09).
#
#  Usage:
#       ./install.sh                              # interactive: asks what to do
#       ./install.sh --role developer             # rtmo: validate, build, push
#       sudo ./install.sh --role device           # rtmod, deploy-manager image, Redis
#       sudo ./install.sh --role developer --role device   # one machine does both
#
#  Interactive mode asks, in this order:
#       1. install or uninstall
#       2. the role (when the device role is chosen, it starts again with sudo)
#       3. install: the checks always run here, a failure stops the script
#       4. install, device role: the CPU of Redis and rtmod (infra_cpu)
#       5. the confirmation: nothing is changed before this answer
#
#  Options:
#       --interactive ask for what the other options do not say
#       --install     install (the default with --role)
#       --no-banner   do not print the banner at the start
#       --check       only verify the prerequisites, change nothing
#       --uninstall   remove the launchers, the virtual environment and (device)
#                     the Redis container; keeps /etc/rtmo and the deploy-manager
#                     image (interactive mode asks about these two)
#
#  Running it again repairs or updates the installation. Every file written
#  outside the checkout is printed.
# ============================================================================


# Configure the bash script (e - exit at the first fault command; u - error when you use unset variable; o pipefail - a pipeline fails if any command in it fails)
set -euo pipefail

# Include some helper functions
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/scripts/lib.sh"

# Set the input parameters (for understand what condition run)
ARGS="$*"
INTERACTIVE=0; [ $# -gt 0 ] || INTERACTIVE=1
DEVELOPER=0 DEVICE=0 CHECK=0 ACTION="" BANNER=1
while [ $# -gt 0 ]; do
    case "$1" in
        --role)
            case "${2:-}" in
                developer) DEVELOPER=1 ;;
                device) DEVICE=1 ;;
                *) die "--role takes 'developer' or 'device'" ;;
            esac
            shift 2 ;;
        --interactive) INTERACTIVE=1; shift ;;
        --install) ACTION="install"; shift ;;
        --no-banner) BANNER=0; shift ;;
        --check) CHECK=1; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done
[ "$CHECK" = 0 ] || [ "$ACTION" != "uninstall" ] || die "--check and --uninstall cannot be used together"
[ "$INTERACTIVE" = 0 ] || [ -t 0 ] || die "no terminal to ask on: give at least one --role developer|device"

# print_banner: the name of the project, its version and its commit
print_banner() {
    local commit
    commit="$(rtmo_commit "$ROOT")"
    printf '%s' "$C_GRN" >&2
    cat >&2 <<'BANNER_TEXT'

  ____  _____ __  __  ___
 |  _ \|_   _|  \/  |/ _ \
 | |_) | | | | |\/| | | | |
 |  _ <  | | | |  | | |_| |
 |_| \_\ |_| |_|  |_|\___/

BANNER_TEXT
    printf '%s' "$C_OFF" >&2
    echo " Real-Time Microservices Orchestration" >&2
    echo " Version $(rtmo_version "$ROOT")${commit:+ ($commit)}" >&2
    echo >&2
}

# Show the banner (only once: the restart with sudo gives --no-banner)
[ "$BANNER" = 0 ] || print_banner

# Ask for the action (interactive)
if [ "$INTERACTIVE" = 1 ] && [ -z "$ACTION" ] && [ "$CHECK" = 0 ]; then
    answer="$(ask_choice "What do you want to do?" "Install" "Uninstall")"
    case "$answer" in
        Install) ACTION="install" ;;
        Uninstall) ACTION="uninstall" ;;
    esac
fi
ACTION="${ACTION:-install}"

# Ask for the role (interactive)
if [ "$INTERACTIVE" = 1 ] && [ "$DEVELOPER$DEVICE" = "00" ]; then
    answer="$(ask_choice "Which role does this machine have?" "developer" "device" "developer and device")"
    case "$answer" in
        developer) DEVELOPER=1 ;;
        device) DEVICE=1 ;;
        "developer and device") DEVELOPER=1; DEVICE=1 ;;
    esac
fi
[ "$DEVELOPER$DEVICE" != "00" ] || die "give at least one --role developer|device"


VERSION="$(rtmo_version "$ROOT")"
DONE="installed"; [ "$CHECK" = 1 ] && DONE="checked"
COMMIT="$(rtmo_commit "$ROOT")"
IS_ROOT=0; [ "$(id -u)" = "0" ] && IS_ROOT=1
BIN_DIR="/usr/local/bin"; [ "$IS_ROOT" = 1 ] || BIN_DIR="$HOME/.local/bin"
DM_IMAGE="rtmo/deploy-manager:$VERSION"
PYTHON=""
VENV_OK=0
INFRA_CPU_CHOICE=""

# The device role needs root: in interactive mode start again with sudo, keeping the answers
if [ "$DEVICE" = 1 ] && [ "$IS_ROOT" = 0 ] && [ "$CHECK" = 0 ]; then
    [ "$INTERACTIVE" = 1 ] || die "--role device needs root: sudo $0 $ARGS"
    need_cmd sudo "run this script as root"
    info "the device role needs root: starting again with sudo"
    ROLES=()
    [ "$DEVELOPER" = 0 ] || ROLES+=(--role developer)
    ROLES+=(--role device)
    exec sudo "$0" --no-banner --interactive "--$ACTION" "${ROLES[@]}"
fi


# write_launcher <name>: scripts/launchers/<name> -> $BIN_DIR/<name>
write_launcher() {
    local name="$1" python="${2:-}" target="$BIN_DIR/$1"
    mkdir -p "$BIN_DIR"
    sed -e "s#@RTMO_HOME@#$ROOT#g" -e "s#@PYTHON@#$python#g" "$ROOT/scripts/launchers/$name" > "$target"
    chmod 755 "$target"
    info "wrote $target"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on your PATH" ;; esac
}

# read_infra_cpu: infra_cpu of /etc/rtmo/device.yaml (empty when it is not set)
read_infra_cpu() {
    sed -nE 's/^infra_cpu:[[:space:]]*([0-9]+).*/\1/p' /etc/rtmo/device.yaml 2>/dev/null | head -n1 || true
}

# warn_infra_cpu <cpu>: core 4 is the control core of the benchmark scenarios
warn_infra_cpu() {
    if [ "$1" = "4" ]; then
        warn "infra_cpu is 4 in /etc/rtmo/device.yaml, the control core of the benchmark scenarios:" \
             "Redis and rtmod share it with the control threads. To move them to core 3:" \
             "sudo sed -i 's/^infra_cpu:.*/infra_cpu: 3/' /etc/rtmo/device.yaml, then run this script again"
    fi
}

# online_cpus: the ids of the online CPUs, one per line
online_cpus() {
    local part parts
    IFS=, read -ra parts < /sys/devices/system/cpu/online
    for part in "${parts[@]}"; do
        case "$part" in
            *-*) seq "${part%-*}" "${part#*-}" ;;
            *) echo "$part" ;;
        esac
    done
}

# ask_infra_cpu: show the available CPUs and set INFRA_CPU_CHOICE
ask_infra_cpu() {
    local answer current default
    local available=()
    mapfile -t available < <(online_cpus)

    # Show the CPUs (lscpu also gives the speed, useful on big.LITTLE boards)
    info "available CPUs: ${available[*]}"
    lscpu --online --extended=CPU,MAXMHZ >&2 2>/dev/null || true

    # The default is the current value, or 3, when that CPU is available
    current="$(read_infra_cpu)"
    default="${current:-3}"
    case " ${available[*]} " in *" $default "*) ;; *) default="${available[0]}" ;; esac

    while true; do
        printf 'CPU of Redis and rtmod (infra_cpu) [%s]: ' "$default" >&2
        read -r answer || die "no answer from the terminal"
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]]; then
            case " ${available[*]} " in *" $answer "*) break ;; esac
        fi
        warn "'$answer' is not an available CPU (available: ${available[*]})"
    done
    INFRA_CPU_CHOICE="$answer"
    warn_infra_cpu "$INFRA_CPU_CHOICE"
}

# use_system_python: no virtual environment, fall back on the system python3
use_system_python() {
    if python3 -c 'import yaml, docker' 2>/dev/null; then
        PYTHON="$(command -v python3)"
        warn "no virtual environment (python3-venv missing): using the system python3 and its" \
             "PyYAML $(python3 -c 'import yaml; print(yaml.__version__)'), docker $(python3 -c 'import docker; print(docker.__version__)')" \
             "instead of the pinned versions in tooling/builder/requirements.txt"
    else
        die "cannot create a virtual environment and the system python3 lacks PyYAML/docker. Install one of:
       sudo apt install python3-venv        (then run this script again)
       sudo apt install python3-yaml python3-docker"
    fi
}

# Check the prerequisites of both roles
check_common() {
    # - Git
    need_cmd git "sudo apt install git"
    # - Docker
    need_cmd docker "https://docs.docker.com/engine/install/"
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing: sudo apt install docker-compose-plugin"
    # - Python
    need_cmd python3 "sudo apt install python3"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "Python >= 3.10 is required ($(python3 --version))"
    # Conferm messagge
    ok "git, docker, docker compose, $(python3 --version)"

    local tag
    tag="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)"
    if [ "$tag" = "v$VERSION" ]; then ok "checkout is on release tag $tag"
    else warn "checkout is not on the release tag v$VERSION (at ${COMMIT:-unknown}): fine for development, install releases from a tag"; fi
}

# Check DEVELOPER
check_developer() {
    python3 -c 'import venv, ensurepip' 2>/dev/null && VENV_OK=1
    if [ "$VENV_OK" = 1 ]; then
        # Check if there is venv and ensurepip
        ok "python3-venv available: a virtual environment will be created in $ROOT/.venv"
    else
        # Without venv, the requirements must be in the system python3
        use_system_python
    fi
    command -v docker >/dev/null && docker buildx version >/dev/null 2>&1 \
        || warn "docker buildx is missing: only needed to build images for another CPU architecture"
}

# Check DEVICE
check_device() {
    # Check if the controlled device is real-time
    if [ "$(cat /sys/kernel/realtime 2>/dev/null || echo 0)" = "1" ]; then ok "PREEMPT_RT kernel"
    else warn "the kernel is not PREEMPT_RT (/sys/kernel/realtime): real-time results will not be meaningful"; fi

    # Check if exisist the mqueue directory
    [ -d /dev/mqueue ] && ok "/dev/mqueue" || warn "/dev/mqueue is missing: the mqueue implementations cannot run"

    # Checks whether the kernel was booted with CPU core isolation
    local iso
    iso="$(tr ' ' '\n' < /proc/cmdline | grep -E '^(isolcpus|nohz_full|rcu_nocbs)=' | tr '\n' ' ' || true)"
    if [ -n "$iso" ]; then ok "core isolation: $iso"
    else info "no core isolation (isolcpus/nohz_full/rcu_nocbs) on the kernel command line: see the plan's open decisions"; fi
}

# Install DEVELOPER
install_developer() {
    if [ "$VENV_OK" = 1 ]; then
        if [ ! -x "$ROOT/.venv/bin/python" ]; then
            # In the case that there is venv, create a venv
            python3 -m venv "$ROOT/.venv" >/dev/null 2>&1 || rm -rf "$ROOT/.venv"
        fi
        if [ -x "$ROOT/.venv/bin/python" ] \
           && "$ROOT/.venv/bin/python" -m pip install -q -r "$ROOT/tooling/builder/requirements.txt"; then
            # After the createtion of venv, install all requirements.txt
            PYTHON="$ROOT/.venv/bin/python"
            ok "virtual environment $ROOT/.venv with tooling/builder/requirements.txt"
        fi
    fi
    # Check if the venv and requirements are installed all ok
    [ -n "$PYTHON" ] || use_system_python
    write_launcher rtmo "$PYTHON"
}

# Install DEVICE
install_device() {
    if [ ! -f /etc/rtmo/device.yaml ]; then
        # Create configuration file for rtmod
        mkdir -p /etc/rtmo
        cp "$ROOT/device/device.yaml.example" /etc/rtmo/device.yaml
        info "wrote /etc/rtmo/device.yaml"
    fi

    # Save the CPU chosen in interactive mode (the comments of the file are kept)
    if [ -n "$INFRA_CPU_CHOICE" ]; then
        if grep -q '^infra_cpu:' /etc/rtmo/device.yaml; then
            sed -i -E "s/^infra_cpu:.*/infra_cpu: $INFRA_CPU_CHOICE/" /etc/rtmo/device.yaml
        else
            echo "infra_cpu: $INFRA_CPU_CHOICE" >> /etc/rtmo/device.yaml
        fi
        info "wrote infra_cpu: $INFRA_CPU_CHOICE in /etc/rtmo/device.yaml"
    fi

    INFRA_CPU="$(read_infra_cpu)"
    export RTMO_INFRA_CPU="${INFRA_CPU:-3}"
    # Interactive mode has already warned, before the confirmation
    [ "$INTERACTIVE" = 1 ] || warn_infra_cpu "$RTMO_INFRA_CPU"

    info "building $DM_IMAGE"
    docker build -q -f "$ROOT/docker/deploy-manager.Dockerfile" \
        --build-arg RTMO_VERSION="$VERSION" --build-arg RTMO_COMMIT="$COMMIT" \
        -t "$DM_IMAGE" "$ROOT" >/dev/null
    ok "image $DM_IMAGE"

    # A 'redis' container of the former per-implementation stacks would block ours.
    local project
    project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' redis 2>/dev/null || true)"
    if [ -n "$project" ] && [ "$project" != "rtmo" ]; then
        warn "removing the old 'redis' container of compose project '$project'"
        docker rm -f redis >/dev/null
    fi
    docker compose -f "$ROOT/device/compose.yaml" up -d --quiet-pull
    ok "Redis running (container 'redis', network 'rtmo', 127.0.0.1:6379, core $RTMO_INFRA_CPU)"

    write_launcher rtmod
}

# UNINSTALL the framework (both roles)
if [ "$ACTION" = "uninstall" ]; then
    REMOVE_CONFIG=0 REMOVE_IMAGE=0
    if [ "$INTERACTIVE" = 1 ]; then
        # Show what will be removed, ask about the extras and then confirm
        [ "$DEVELOPER" = 0 ] || info "to remove: $BIN_DIR/rtmo, $ROOT/.venv"
        [ "$DEVICE" = 0 ] || info "to remove: $BIN_DIR/rtmod, the Redis container"
        if [ "$DEVICE" = 1 ]; then
            if ask_yes_no "Also delete /etc/rtmo (the device settings)?" n; then REMOVE_CONFIG=1; fi
            if ask_yes_no "Also delete the image $DM_IMAGE?" n; then REMOVE_IMAGE=1; fi
        fi
        ask_yes_no "Uninstall now?" n || { info "nothing was changed"; exit 0; }
    fi

    if [ "$DEVELOPER" = 1 ]; then
        rm -f "$BIN_DIR/rtmo" && info "removed $BIN_DIR/rtmo"
        rm -rf "$ROOT/.venv" && info "removed $ROOT/.venv"
        # An installation made with sudo is in another folder, out of reach without root
        hash -r
        still="$(command -v rtmo || true)"
        [ -z "$still" ] || warn "$still is still installed: run this script with sudo to remove it"
    fi
    if [ "$DEVICE" = 1 ]; then
        rm -f "$BIN_DIR/rtmod" && info "removed $BIN_DIR/rtmod"
        docker compose -f "$ROOT/device/compose.yaml" down || true
        if [ "$REMOVE_IMAGE" = 1 ]; then
            if docker image rm "$DM_IMAGE" >/dev/null 2>&1; then info "removed the image $DM_IMAGE"
            else warn "could not remove the image $DM_IMAGE"; fi
        fi
        if [ "$REMOVE_CONFIG" = 1 ]; then
            rm -rf /etc/rtmo && info "removed /etc/rtmo"
        else
            info "kept /etc/rtmo"
        fi
    fi
    exit 0
fi

# Prerequisites: always first, a failure stops here and nothing has been changed
check_common
[ "$DEVELOPER" = 0 ] || check_developer
[ "$DEVICE" = 0 ] || check_device

# Check only: the end
if [ "$CHECK" = 1 ]; then
    [ "$DEVELOPER" = 0 ] || ok "developer role $DONE"
    [ "$DEVICE" = 0 ] || ok "device role $DONE"
    info "check only: nothing was changed"
    info "RTMO $VERSION ${COMMIT:+($COMMIT)} from $ROOT"
    exit 0
fi

# Choose the CPU and confirm (interactive)
if [ "$INTERACTIVE" = 1 ]; then
    [ "$DEVICE" = 0 ] || ask_infra_cpu
    ask_yes_no "The checks are done. Install now?" n || { info "nothing was changed"; exit 0; }
fi

# Install the chosen roles
if [ "$DEVELOPER" = 1 ]; then
    install_developer
    ok "developer role $DONE"
fi
if [ "$DEVICE" = 1 ]; then
    install_device
    ok "device role $DONE"
fi

info "RTMO $VERSION ${COMMIT:+($COMMIT)} from $ROOT"
