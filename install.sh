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
#       3. install: the checks always run here. A missing package is listed
#          and installed after the confirmation; any other failure stops the script
#       4. install, device role: the CPU of Redis and rtmod (infra_cpu)
#       5. the confirmation: nothing is changed before this answer
#
#  Prerequisites installed with apt when missing (sudo is asked when needed):
#       both roles   git, Docker (docker-ce from Docker's repository when it is set
#                    up, else docker.io), python3; a stopped Docker daemon is started
#       developer    python3-venv, docker buildx
#       device       Docker Compose v2, and the build tools of the native runtime:
#                    cmake, build-essential, pkg-config, libglib2.0-dev
#  Checked only (a package cannot fix them): Python >= 3.10, the PREEMPT_RT kernel,
#  /dev/mqueue, core isolation, membership of the 'docker' group.
#
#  Options:
#       --interactive ask for what the other options do not say
#       --install     install (the default with --role)
#       --no-banner   do not print the banner at the start
#       --check       only verify the prerequisites, change nothing (status 1
#                     when the install would add something)
#       --uninstall   remove the launchers, the virtual environment and (device)
#                     the Redis container; keeps /etc/rtmo and the deploy-manager
#                     image (interactive mode asks about these two)
#
#  Running it again repairs or updates the installation. Every file written
#  outside the checkout is printed.
# ============================================================================

# -e: stop at the first failing command; -u: an unset variable is an error;
# pipefail: a pipeline fails when any command in it fails
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/scripts/lib.sh"        # info, ok, warn, die, need_cmd, ask_choice, ask_yes_no


# ============================================================================
#  State
# ============================================================================

# Set by the command line, completed by the interactive questions
ARGS=""                 # the original arguments, for the error messages
INTERACTIVE=0           # 1: ask for what the options do not say
ACTION=""               # install | uninstall
DEVELOPER=0             # 1: the developer role was chosen
DEVICE=0                # 1: the device role was chosen
CHECK=0                 # 1: only check the prerequisites
BANNER=1                # 0: the banner was already printed (restart with sudo)

# Filled by the checks
MISSING_PKGS=()         # apt packages the install adds
START_DOCKER=0          # 1: the install starts the Docker daemon
VENV_OK=0               # 1: python3 can create a virtual environment

# Filled during the install
PYTHON=""               # the python3 of the rtmo launcher
INFRA_CPU_CHOICE=""     # infra_cpu chosen in interactive mode

# Constant for the whole run (set in main, after the root check)
VERSION="" COMMIT="" IS_ROOT=0 BIN_DIR="" DM_IMAGE="" DONE=""


# ============================================================================
#  Command line and interactive questions
# ============================================================================

# parse_args <argument>...: set the options; no argument at all means interactive
parse_args() {
    ARGS="$*"
    [ $# -gt 0 ] || INTERACTIVE=1
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
            --uninstall) ACTION="uninstall"; shift ;;
            --check) CHECK=1; shift ;;
            --no-banner) BANNER=0; shift ;;
            -h|--help) sed -n '2,/^# ====/p' "$0"; exit 0 ;;
            *) die "unknown option '$1' (see --help)" ;;
        esac
    done
    [ "$CHECK" = 0 ] || [ "$ACTION" != "uninstall" ] || die "--check and --uninstall cannot be used together"
    [ "$INTERACTIVE" = 0 ] || [ -t 0 ] || die "no terminal to ask on: give at least one --role developer|device"
}

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

# ask_action: install or uninstall (interactive, when no option says it)
ask_action() {
    local answer
    if [ "$INTERACTIVE" = 1 ] && [ -z "$ACTION" ] && [ "$CHECK" = 0 ]; then
        # An assignment, so that set -e stops the script when ask_choice fails
        answer="$(ask_choice "What do you want to do?" "Install" "Uninstall")"
        case "$answer" in
            Install) ACTION="install" ;;
            Uninstall) ACTION="uninstall" ;;
        esac
    fi
    ACTION="${ACTION:-install}"
}

# ask_role: developer, device or both (interactive, when no --role says it)
ask_role() {
    local answer
    if [ "$INTERACTIVE" = 1 ] && [ "$DEVELOPER$DEVICE" = "00" ]; then
        answer="$(ask_choice "Which role does this machine have?" "developer" "device" "developer and device")"
        case "$answer" in
            developer) DEVELOPER=1 ;;
            device) DEVICE=1 ;;
            "developer and device") DEVELOPER=1; DEVICE=1 ;;
        esac
    fi
    [ "$DEVELOPER$DEVICE" != "00" ] || die "give at least one --role developer|device"
}

# restart_as_root: the device role needs root. Interactive mode starts again with
# sudo and passes on the answers given so far; otherwise the script stops
restart_as_root() {
    [ "$DEVICE" = 1 ] && [ "$IS_ROOT" = 0 ] && [ "$CHECK" = 0 ] || return 0
    [ "$INTERACTIVE" = 1 ] || die "--role device needs root: sudo $0 $ARGS"
    need_cmd sudo "run this script as root"
    info "the device role needs root: starting again with sudo"
    local roles=()
    [ "$DEVELOPER" = 0 ] || roles+=(--role developer)
    roles+=(--role device)
    exec sudo "$0" --no-banner --interactive "--$ACTION" "${roles[@]}"
}


# ============================================================================
#  Helpers
# ============================================================================

# as_root <command>...: run it as root (sudo when this script is not root)
as_root() {
    if [ "$IS_ROOT" = 1 ]; then
        "$@"
    else
        need_cmd sudo "run this script as root"
        sudo "$@" || die "failed as root: $*"
    fi
}

# have <command>: true when the command exists
have() { command -v "$1" >/dev/null 2>&1; }

# want_pkg <apt package> <what is missing>: the install adds this package
want_pkg() {
    case " ${MISSING_PKGS[*]} " in *" $1 "*) return 0 ;; esac
    MISSING_PKGS+=("$1")
    warn "$2 is missing: apt package $1"
}

# apt_pkg <candidate>...: the first package apt can install. Docker's repository
# and the distribution give different names (docker-compose-plugin / docker-compose-v2)
apt_pkg() {
    local p
    if have apt-cache; then
        for p in "$@"; do
            if [ -n "$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | grep -v '(none)')" ]; then
                echo "$p"; return 0
            fi
        done
    fi
    echo "$1"
}

# device_compose <compose args>...: docker compose on device/compose.yaml, with the
# variables it reads (RTMO_INFRA_CPU is exported by install_device, default 3)
device_compose() {
    RTMO_VERSION="$VERSION" RTMO_COMMIT="$COMMIT" \
        docker compose -f "$ROOT/device/compose.yaml" "$@"
}

# write_launcher <name> [python]: scripts/launchers/<name> -> $BIN_DIR/<name>
write_launcher() {
    local name="$1" python="${2:-}" target="$BIN_DIR/$1"
    mkdir -p "$BIN_DIR"
    sed -e "s#@RTMO_HOME@#$ROOT#g" -e "s#@PYTHON@#$python#g" "$ROOT/scripts/launchers/$name" > "$target"
    chmod 755 "$target"
    info "wrote $target"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on your PATH" ;; esac
}

# use_system_python: no virtual environment, fall back on the system python3
use_system_python() {
    if python3 -c 'import yaml, docker' 2>/dev/null; then
        PYTHON="$(command -v python3)"
        warn "no virtual environment (python3-venv missing): using the system python3 and its" \
             "PyYAML $(python3 -c 'import yaml; print(yaml.__version__)'), docker $(python3 -c 'import docker; print(docker.__version__)')" \
             "instead of the pinned versions in toolchain/builder/requirements.txt"
    else
        die "cannot create a virtual environment and the system python3 lacks PyYAML/docker. Install one of:
       sudo apt install python3-venv        (then run this script again)
       sudo apt install python3-yaml python3-docker"
    fi
}


# ============================================================================
#  infra_cpu: the CPU of Redis and rtmod (/etc/rtmo/device.yaml)
# ============================================================================

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


# ============================================================================
#  Checks
#
#  A check never stops at a missing package: it adds the package to MISSING_PKGS
#  (want_pkg), and the install adds them all with apt after the confirmation.
#  What a package cannot fix (the kernel, an old Python) warns or stops.
# ============================================================================

# --- Both roles -------------------------------------------------------------

check_git() {
    if have git; then ok "git $(git --version | awk '{print $3}')"
    else want_pkg git "git"; fi
}

# check_docker: the CLI. A system without Docker gets docker-ce when Docker's apt
# repository is set up (as Compose and buildx do: the two sources must not be
# mixed), else the distribution's docker.io
check_docker() {
    if have docker; then
        ok "docker CLI $(docker --version | awk '{print $3}' | tr -d ,)"
    elif [ "$(apt_pkg docker-ce docker.io)" = "docker-ce" ]; then
        want_pkg docker-ce "Docker"
        want_pkg docker-ce-cli "the Docker CLI"
        want_pkg containerd.io "containerd"
    else
        want_pkg docker.io "Docker"
    fi
}

# check_docker_daemon: the daemon must run; the install starts a stopped one
check_docker_daemon() {
    if ! have docker; then
        START_DOCKER=1          # docker is being installed: make sure it runs and starts at boot
    elif docker info >/dev/null 2>&1; then
        ok "Docker daemon $(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    elif have systemctl && ! systemctl is-active --quiet docker; then
        START_DOCKER=1
        warn "the Docker daemon is not running: the install starts it (systemctl enable --now docker)"
    elif [ "$IS_ROOT" = 0 ] && ! id -nG | tr ' ' '\n' | grep -qx docker; then
        warn "the Docker daemon runs, but $(id -un) cannot use it (not in the 'docker' group)." \
             "To add it: sudo usermod -aG docker $(id -un), then log in again"
    else
        die "cannot reach the Docker daemon: docker info"
    fi
}

check_python() {
    if have python3; then
        python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
            || die "Python >= 3.10 is required ($(python3 --version)): this distribution is too old"
        ok "$(python3 --version)"
    else
        want_pkg python3 "Python 3"
    fi
}

# check_release_tag: a release is installed from its tag (only a warning)
check_release_tag() {
    local tag
    tag="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)"
    if [ "$tag" = "v$VERSION" ]; then ok "checkout is on release tag $tag"
    else warn "checkout is not on the release tag v$VERSION (at ${COMMIT:-unknown}): fine for development, install releases from a tag"; fi
}

# --- Developer role ---------------------------------------------------------

# check_venv: the pinned toolchain/builder/requirements.txt go into $ROOT/.venv
check_venv() {
    VENV_OK=0
    if have python3 && python3 -c 'import venv, ensurepip' 2>/dev/null; then
        VENV_OK=1
        ok "python3-venv: a virtual environment will be created in $ROOT/.venv"
    else
        want_pkg python3-venv "python3-venv (the virtual environment of rtmo)"
    fi
}

# check_buildx: rtmo build for another CPU architecture
check_buildx() {
    if docker buildx version >/dev/null 2>&1; then ok "docker buildx $(docker buildx version | awk '{print $2}')"
    else want_pkg "$(apt_pkg docker-buildx-plugin docker-buildx)" "docker buildx"; fi
}

# --- Device role ------------------------------------------------------------

check_realtime_kernel() {
    if [ "$(cat /sys/kernel/realtime 2>/dev/null || echo 0)" = "1" ]; then ok "PREEMPT_RT kernel"
    else warn "the kernel is not PREEMPT_RT (/sys/kernel/realtime): real-time results will not be meaningful"; fi
}

# check_compose: the install starts Redis with device/compose.yaml
check_compose() {
    if docker compose version >/dev/null 2>&1; then ok "Docker Compose $(docker compose version --short 2>/dev/null || true)"
    else want_pkg "$(apt_pkg docker-compose-plugin docker-compose-v2)" "Docker Compose v2"; fi
}

# check_native_build_tools: the native runtime compiles on this host
# (tests/start-test/native.sh); the other runtimes compile inside their images
check_native_build_tools() {
    local cmake_v
    if have cmake; then
        cmake_v="$(cmake --version | awk 'NR==1 {print $3}')"
        if printf '3.20\n%s\n' "$cmake_v" | sort -V -C; then ok "cmake $cmake_v"
        else warn "cmake $cmake_v is older than 3.20: the native runtime will not build"; fi
    else
        want_pkg cmake "cmake (native runtime)"
    fi
    have gcc && have make || want_pkg build-essential "gcc/make (native runtime)"
    have pkg-config || want_pkg pkg-config "pkg-config (native runtime)"
    if pkg-config --exists glib-2.0 gio-2.0 2>/dev/null; then ok "GLib/GIO $(pkg-config --modversion glib-2.0)"
    else want_pkg libglib2.0-dev "the GLib/GIO headers (native runtime)"; fi
}

check_mqueue() {
    if [ -d /dev/mqueue ]; then ok "/dev/mqueue"
    else warn "/dev/mqueue is missing: the mqueue implementations cannot run"; fi
}

# check_core_isolation: was the kernel booted with CPU core isolation (only informative)
check_core_isolation() {
    local iso
    iso="$(tr ' ' '\n' < /proc/cmdline | grep -E '^(isolcpus|nohz_full|rcu_nocbs)=' | tr '\n' ' ' || true)"
    if [ -n "$iso" ]; then ok "core isolation: $iso"
    else info "no core isolation (isolcpus/nohz_full/rcu_nocbs) on the kernel command line: see the plan's open decisions"; fi
}

# --- All the checks of the chosen roles -------------------------------------

# run_checks: start from scratch, then fill MISSING_PKGS and START_DOCKER
run_checks() {
    MISSING_PKGS=()
    START_DOCKER=0

    check_git
    check_docker
    check_docker_daemon
    check_python
    check_release_tag

    if [ "$DEVELOPER" = 1 ]; then
        check_venv
        check_buildx
    fi

    if [ "$DEVICE" = 1 ]; then
        check_realtime_kernel
        check_compose
        check_native_build_tools
        check_mqueue
        check_core_isolation
    fi
}

# prerequisites_to_fix: what the install will add (empty when nothing)
prerequisites_to_fix() {
    local what=""
    [ "${#MISSING_PKGS[@]}" = 0 ] || what="apt packages: ${MISSING_PKGS[*]}"
    [ "$START_DOCKER" = 0 ] || what="${what:+$what; }start the Docker daemon"
    echo "$what"
}


# ============================================================================
#  Install
# ============================================================================

# install_prerequisites: install the missing packages and start the Docker daemon
install_prerequisites() {
    if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
        have apt-get || die "no apt-get on this system: install these yourself (Debian/Ubuntu names): ${MISSING_PKGS[*]}"
        info "installing ${MISSING_PKGS[*]}"
        as_root apt-get update -q
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${MISSING_PKGS[@]}"
        ok "installed ${MISSING_PKGS[*]}"
    fi
    if [ "$START_DOCKER" = 1 ]; then
        have systemctl || die "cannot start the Docker daemon: no systemctl on this system"
        as_root systemctl enable --now docker
        ok "Docker daemon started"
    fi
}

# install_developer: the virtual environment and the rtmo launcher
install_developer() {
    # The virtual environment with the pinned requirements (created once, updated every run)
    if [ "$VENV_OK" = 1 ]; then
        if [ ! -x "$ROOT/.venv/bin/python" ]; then
            python3 -m venv "$ROOT/.venv" >/dev/null 2>&1 || rm -rf "$ROOT/.venv"
        fi
        if [ -x "$ROOT/.venv/bin/python" ] \
           && "$ROOT/.venv/bin/python" -m pip install -q -r "$ROOT/toolchain/builder/requirements.txt"; then
            PYTHON="$ROOT/.venv/bin/python"
            ok "virtual environment $ROOT/.venv with toolchain/builder/requirements.txt"
        fi
    fi
    # Without it (no venv, or pip failed), the system python3 must have the requirements
    [ -n "$PYTHON" ] || use_system_python
    write_launcher rtmo "$PYTHON"
}

# install_device: /etc/rtmo/device.yaml, the deploy-manager image, Redis and the rtmod launcher
install_device() {
    # The settings of rtmod (an existing file is kept)
    if [ ! -f /etc/rtmo/device.yaml ]; then
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

    local infra_cpu
    infra_cpu="$(read_infra_cpu)"
    export RTMO_INFRA_CPU="${infra_cpu:-3}"        # read by device/compose.yaml
    # Interactive mode has already warned, before the confirmation
    [ "$INTERACTIVE" = 1 ] || warn_infra_cpu "$RTMO_INFRA_CPU"

    # The deploy-manager image (rtmod runs in it)
    info "building $DM_IMAGE"
    device_compose --profile cli build --quiet deploy-manager >/dev/null
    ok "image $DM_IMAGE"

    # Redis. A 'redis' container of the former per-implementation stacks would block ours
    local project
    project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' redis 2>/dev/null || true)"
    if [ -n "$project" ] && [ "$project" != "rtmo" ]; then
        warn "removing the old 'redis' container of compose project '$project'"
        docker rm -f redis >/dev/null
    fi
    device_compose up -d --quiet-pull
    ok "Redis running (container 'redis', network 'rtmo', 127.0.0.1:6379, core $RTMO_INFRA_CPU)"

    write_launcher rtmod
}


# ============================================================================
#  Uninstall
# ============================================================================

uninstall() {
    local remove_config=0 remove_image=0 still

    # Interactive: show what will be removed, ask about the extras, then confirm
    if [ "$INTERACTIVE" = 1 ]; then
        [ "$DEVELOPER" = 0 ] || info "to remove: $BIN_DIR/rtmo, $ROOT/.venv"
        [ "$DEVICE" = 0 ] || info "to remove: $BIN_DIR/rtmod, the Redis container"
        if [ "$DEVICE" = 1 ]; then
            if ask_yes_no "Also delete /etc/rtmo (the device settings)?" n; then remove_config=1; fi
            if ask_yes_no "Also delete the image $DM_IMAGE?" n; then remove_image=1; fi
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
        device_compose down || true
        if [ "$remove_image" = 1 ]; then
            if docker image rm "$DM_IMAGE" >/dev/null 2>&1; then info "removed the image $DM_IMAGE"
            else warn "could not remove the image $DM_IMAGE"; fi
        fi
        if [ "$remove_config" = 1 ]; then
            rm -rf /etc/rtmo && info "removed /etc/rtmo"
        else
            info "kept /etc/rtmo"
        fi
    fi
}


# ============================================================================
#  Main
# ============================================================================

main() {
    local to_fix

    # 1. What to do: the options, then the questions for what they do not say
    parse_args "$@"
    [ "$BANNER" = 0 ] || print_banner       # only once: the restart with sudo gives --no-banner
    ask_action
    ask_role

    # 2. The values of this run
    VERSION="$(rtmo_version "$ROOT")"
    COMMIT="$(rtmo_commit "$ROOT")"
    IS_ROOT=0; [ "$(id -u)" = "0" ] && IS_ROOT=1
    BIN_DIR="/usr/local/bin"; [ "$IS_ROOT" = 1 ] || BIN_DIR="$HOME/.local/bin"
    DM_IMAGE="rtmo/deploy-manager:$VERSION"
    DONE="installed"; [ "$CHECK" = 0 ] || DONE="checked"
    restart_as_root

    # 3. Uninstall: no checks needed
    if [ "$ACTION" = "uninstall" ]; then
        uninstall
        exit 0
    fi

    # 4. The checks: always first. A failure that a package cannot fix stops here,
    #    and nothing has been changed; the missing packages are only collected
    run_checks
    to_fix="$(prerequisites_to_fix)"

    # 5. Check only: the end (status 1 when something is missing)
    if [ "$CHECK" = 1 ]; then
        info "check only: nothing was changed"
        if [ -n "$to_fix" ]; then
            warn "the install would add: $to_fix"
            exit 1
        fi
        [ "$DEVELOPER" = 0 ] || ok "developer role $DONE"
        [ "$DEVICE" = 0 ] || ok "device role $DONE"
        info "RTMO $VERSION ${COMMIT:+($COMMIT)} from $ROOT"
        exit 0
    fi

    # 6. Interactive: choose the CPU and confirm. Nothing is changed before this answer
    if [ "$INTERACTIVE" = 1 ]; then
        [ "$DEVICE" = 0 ] || ask_infra_cpu
        [ -z "$to_fix" ] || info "the install will also add: $to_fix"
        ask_yes_no "The checks are done. Install now?" n || { info "nothing was changed"; exit 0; }
    fi

    # 7. Install the missing prerequisites, then check again: now nothing may be missing
    if [ -n "$to_fix" ]; then
        install_prerequisites
        hash -r
        info "checking the prerequisites again"
        run_checks
        to_fix="$(prerequisites_to_fix)"
        [ -z "$to_fix" ] || die "still missing after the install: $to_fix"
    fi

    # 8. Install the chosen roles
    if [ "$DEVELOPER" = 1 ]; then
        install_developer
        ok "developer role $DONE"
    fi
    if [ "$DEVICE" = 1 ]; then
        install_device
        ok "device role $DONE"
    fi

    info "RTMO $VERSION ${COMMIT:+($COMMIT)} from $ROOT"
}

main "$@"
