#!/usr/bin/env bash
# ============================================================================
#  run-test.sh: one test run of one manifest, on top of rtmo and rtmod.
#
#  Usage:
#       tools/run-test.sh <manifest> [test-name] [--coordination C] [--technology T] [--iterations N]
#                         [--no-build]
#
#    --no-build: skip step 1, for a device that got the images with 'rtmo push'
#    (two-machine test). Give the manifest pushed to the device
#    (/srv/rtmo/apps/<app>/<manifest>.yaml) and the same overrides as for
#    'rtmo build' and 'rtmo push'; only rtmod is needed on the device.
#
#    1. rtmo build    (task images, execution manager, lock file)
#    2. rtmod stop    (containers of a previous run); choreography-mqueue: empty /dev/mqueue
#    3. rtmod apply   (task containers, plan in Redis, execution manager)
#    4. follow the run until it ends: the execution manager (orchestration) or
#       every task container (choreography); Ctrl+C stops it early
#    5. save the logs, rtmod stop, performance report
#
#  Results: results/<coordination>-<technology>/<test-name>/ (a random name when
#  none is given): logs/, manifest.yaml (with the overrides), perf.csv,
#  stats.csv, report.pdf. FORCE=1 overwrites an existing folder.
#
#  Needs rtmo and rtmod on the PATH (install.sh --role developer --role device);
#  with --no-build only rtmod.
# ============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/report-lib.sh"

MANIFEST="" NAME="" OVERRIDES=() BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --coordination|--technology|--iterations)
            [ $# -ge 2 ] || { echo "[ERROR] $1 needs a value" >&2; exit 2; }
            OVERRIDES+=("$1" "$2"); shift 2 ;;
        -*) echo "[ERROR] unknown option $1" >&2; exit 2 ;;
        *) if [ -z "$MANIFEST" ]; then MANIFEST="$1"; elif [ -z "$NAME" ]; then NAME="$1";
           else echo "[ERROR] unexpected argument $1" >&2; exit 2; fi; shift ;;
    esac
done
[ -n "$MANIFEST" ] || { sed -n '4,7p' "$0" >&2; exit 2; }
NEEDED=(rtmod); [ "$BUILD" = 0 ] || NEEDED=(rtmo rtmod)
for cmd in "${NEEDED[@]}"; do
    command -v "$cmd" >/dev/null || { echo "[ERROR] '$cmd' not found: run install.sh --role developer --role device" >&2; exit 1; }
done

# effective <profile|manifest>: the implementation name, or the manifest with the
# overrides applied. rtmo when installed, else the DSL with the system python3
# (a device has only rtmod; rtmod apply validates the manifest anyway).
effective() {
    if command -v rtmo >/dev/null; then
        rtmo validate "$MANIFEST" "${OVERRIDES[@]}" --print "$1"
    else
        PYTHONPATH="$ROOT/toolchain" python3 - "$1" "$MANIFEST" "${OVERRIDES[@]}" <<'PY'
import argparse, sys, yaml
from dsl.overrides import add_arguments, from_arguments, override, read
what, path = sys.argv[1], sys.argv[2]
ap = argparse.ArgumentParser(); add_arguments(ap)
data = override(read(path), **from_arguments(ap.parse_args(sys.argv[3:])))
if what == "profile":
    d = data["deployment"]; print(f"{d['coordination']}-{d['technology']}")
else:
    sys.stdout.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False, width=100))
PY
    fi
}

PROFILE="$(effective profile)" || exit 1
rl_init_results "$ROOT/results/$PROFILE" "$NAME" || exit 1
EFFECTIVE="$(mktemp)"
trap 'rm -f "$EFFECTIVE"' EXIT
effective manifest > "$EFFECTIVE" || exit 1

if [ "$BUILD" = 1 ]; then
    echo "=== [1/5] Build ($PROFILE) ==="
    rtmo build "$MANIFEST" "${OVERRIDES[@]}" || { echo "[ERROR] build failed" >&2; exit 1; }
else
    echo "=== [1/5] Build: skipped (--no-build, images pushed with rtmo push) ==="
fi

echo "=== [2/5] Clean up the previous run ==="
rtmod stop || true
if [ "$PROFILE" = "choreography-mqueue" ] && [ -d /dev/mqueue ]; then
    rm -f /dev/mqueue/* 2>/dev/null || sudo rm -f /dev/mqueue/* 2>/dev/null || true
fi

echo "=== [3/5] Apply ==="
rtmod apply "$MANIFEST" "${OVERRIDES[@]}" 2>&1 | tee "$LOG_DIR/deploy-manager.log"
if [ "${PIPESTATUS[0]}" != "0" ]; then
    echo "[ERROR] rtmod apply failed (see $LOG_DIR/deploy-manager.log)" >&2
    rl_save_container_logs redis
    rtmod stop >/dev/null 2>&1 || true
    exit 1
fi

TASKS=() EM=""
while read -r role name; do
    case "$role" in
        task) TASKS+=("$name") ;;
        execution-manager) EM="$name" ;;
    esac
done < <(rtmod status --containers)

echo "=== [4/5] Run (Ctrl+C to stop early) ==="
INTERRUPTED=0
on_interrupt() {
    INTERRUPTED=1
    echo; echo "[INFO] Interrupted: stopping, reporting on the data collected so far..."
    for c in ${EM:+"$EM"} "${TASKS[@]}"; do docker stop "$c" >/dev/null 2>&1 || true; done
}
trap on_interrupt INT TERM

if [ -n "$EM" ]; then
    # orchestration: the run ends when the execution manager exits
    docker logs -f "$EM" 2>&1 | tee "$LOG_DIR/execution-manager.log" || true
    code="$(docker inspect -f '{{.State.ExitCode}}' "$EM" 2>/dev/null || echo missing)"
    [ "$code" = "0" ] || echo "[WARN] execution manager '$EM' exited with code $code"
    rl_save_container_logs "${TASKS[@]}"
else
    # choreography: the run ends when every task container exits
    pids=()
    for c in "${TASKS[@]}"; do rl_follow_container "$c" & pids+=($!); done
    wait "${pids[@]}" || true
    wait || true
    for c in "${TASKS[@]}"; do
        code="$(docker inspect -f '{{.State.ExitCode}}' "$c" 2>/dev/null || echo missing)"
        [ "$code" = "0" ] || echo "[WARN] task container '$c' exited with code $code"
    done
fi
trap - INT TERM

echo "=== [5/5] Logs, stop, report ==="
rl_save_container_logs redis
rtmod stop >/dev/null || true
REPORT_RC=0
rl_generate_report "$ROOT" "$PROFILE" "$EFFECTIVE" || REPORT_RC=$?
echo "[INFO] Done. Results: $RESULTS_DIR"
[ "$INTERRUPTED" = 1 ] && exit 130
exit $REPORT_RC
