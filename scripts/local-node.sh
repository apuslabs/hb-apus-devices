#!/usr/bin/env bash
# Run a HyperBEAM node in the background with the devices of a preloaded
# store, for smoke tests and local development. `make local` starts the same
# kind of node in an interactive shell instead.
#
# Usage: scripts/local-node.sh start|stop|restart|status|logs
#
# Environment:
#   PRELOADED_STORE  store to load devices from (default: _build/preloaded-store,
#                    built by `make preload`)
#   HB_PORT          HTTP port (default: 8734)
#   HB_CONFIG        node configuration file (default: config.flat in the
#                    repository root, when present)
#   NODE_DIR         working directory of the node: pid file, log, node
#                    wallet and cache (default: _build/local-node)
#   START_TIMEOUT    seconds to wait for the node to answer (default: 60)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

absolute() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$root/$1" ;;
    esac
}

store=$(absolute "${PRELOADED_STORE:-_build/preloaded-store}")
port=${HB_PORT:-8734}
node_dir=$(absolute "${NODE_DIR:-_build/local-node}")
start_timeout=${START_TIMEOUT:-60}
pid_file=$node_dir/node.pid
log_file=$node_dir/node.log
url=http://localhost:$port

running() {
    [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

answering() {
    curl -fsS -o /dev/null --max-time 5 "$url/~meta@1.0/info" 2>/dev/null
}

start() {
    if running; then
        echo "node already running (pid $(cat "$pid_file")) at $url"
        return 0
    fi
    if [ ! -f "$store/data.mdb" ]; then
        echo "error: no preloaded store at $store; run make preload first" >&2
        exit 1
    fi
    if [ ! -d "$root/_build/default/lib/hb/ebin" ]; then
        echo "error: HyperBEAM is not compiled; run make compile first" >&2
        exit 1
    fi
    config=${HB_CONFIG:-}
    if [ -z "$config" ] && [ -f "$root/config.flat" ]; then
        config=$root/config.flat
    fi
    mkdir -p "$node_dir"
    (
        cd "$node_dir"
        export HB_PRELOADED_STORE="$store" HB_PORT="$port"
        if [ -n "$config" ]; then
            export HB_CONFIG="$(absolute "$config")"
        fi
        nohup erl -noinput -pa "$root"/_build/default/lib/*/ebin \
            -eval '{ok, _} = application:ensure_all_started(hb).' \
            > "$log_file" 2>&1 &
        echo $! > "$pid_file"
    )
    echo "starting node (pid $(cat "$pid_file")) at $url with store $store"
    for _ in $(seq "$start_timeout"); do
        if answering; then
            echo "node ready at $url"
            return 0
        fi
        if ! running; then
            echo "error: node exited during start; last log lines:" >&2
            tail -n 40 "$log_file" >&2
            rm -f "$pid_file"
            exit 1
        fi
        sleep 1
    done
    echo "error: node did not answer within ${start_timeout}s; see $log_file" >&2
    exit 1
}

stop() {
    if ! running; then
        echo "node not running"
        rm -f "$pid_file"
        return 0
    fi
    pid=$(cat "$pid_file")
    kill "$pid"
    for _ in $(seq 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid"
    fi
    rm -f "$pid_file"
    echo "node stopped"
}

status() {
    if running; then
        if answering; then
            echo "node running (pid $(cat "$pid_file")) and answering at $url"
        else
            echo "node running (pid $(cat "$pid_file")) but not answering at $url"
            return 1
        fi
    else
        echo "node not running"
        return 1
    fi
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    logs) tail -n "${LINES:-100}" "$log_file" ;;
    *)
        echo "usage: scripts/local-node.sh start|stop|restart|status|logs" >&2
        exit 2
        ;;
esac
