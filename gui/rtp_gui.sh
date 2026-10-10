#!/usr/bin/env bash

set -euo pipefail

GUI_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd -- "$GUI_DIR/../src" && pwd)"
SENDER="$SRC_DIR/rtp_send.sh"
RECEIVER="$SRC_DIR/rtp_receive.sh"

function show_error() {
    if ! yad --text-info \
        --title="RTP Audio" \
        --text="$1" \
        --image=dialog-error \
        --width=440 --height=160 \
        --button=OK; then
        printf 'Error: %s\n' "$1" >&2
    fi
}

function require_dependencies() {
    local command

    for command in yad pactl; do
        if ! command -v "$command" >/dev/null 2>&1; then
            printf 'Error: required command not found: %s\n' "$command" >&2
            exit 1
        fi
    done

    if ! pactl info >/dev/null 2>&1; then
        show_error "Cannot connect to the PulseAudio-compatible server (pipewire-pulse)."
        exit 1
    fi
}

function combo_values() {
    awk -v prefix="$1" '
        BEGIN {
            if (prefix != "") {
                printf "%s", prefix
                first = 0
            } else {
                first = 1
            }
        }
        {
            printf "%s%s", first ? "" : "!", $2
            first = 0
        }'
}

function choose_mode() {
    yad --list \
        --title="RTP Audio" \
        --text="Choose an operation" \
        --radiolist \
        --column="" --column="Mode" \
        TRUE Sender FALSE Receiver \
        --print-column=2 \
        --width=320 --height=180 \
        --button=Cancel:1 --button=Continue:0
}

function sender_form() {
    local sources form_data
    sources="$(pactl list short sources | combo_values "")"
    if [[ -z "$sources" ]]; then
        show_error "No PulseAudio/PipeWire sources are available."
        return 1
    fi

    if ! form_data=$(yad --form \
        --title="RTP Audio Sender" \
        --text="Send Opus audio over RTP" \
        --field="Capture source:CB" "$sources" \
        --field="Sender IPv4 (optional)" "" \
        --field="Receiver IPv4" "" \
        --field="Port" "4010" \
        --field="RTP MTU" "1200" \
        --field="Opus bitrate (bits/s)" "64000" \
        --width=520 --height=300 \
        --button=Cancel:1 --button=Start:0); then
        return 1
    fi

    local source sender_ip receiver_ip port mtu bitrate
    IFS='|' read -r source sender_ip receiver_ip port mtu bitrate <<< "$form_data"
    local -a args=(--source "$source" --receiver-ip "$receiver_ip" --port "$port" --mtu "$mtu" --bitrate "$bitrate")
    if [[ -n "$sender_ip" ]]; then
        args+=(--sender-ip "$sender_ip")
    fi
    run_session "Sender" "$SENDER" "${args[@]}"
}

function receiver_form() {
    local sinks form_data
    sinks="$(pactl list short sinks | combo_values "None")"
    if [[ "$sinks" == "None" ]]; then
        sinks="None"
    fi

    if ! form_data=$(yad --form \
        --title="RTP Audio Receiver" \
        --text="Receive and decode Opus RTP audio" \
        --field="Port" "4010" \
        --field="Receiver IPv4 (optional)" "" \
        --field="Expected sender IPv4 (optional)" "" \
        --field="Playback sink:CB" "$sinks" \
        --field="Jitter buffer (ms)" "200" \
        --field="Loopback latency (ms)" "50" \
        --width=520 --height=300 \
        --button=Cancel:1 --button=Start:0); then
        return 1
    fi

    local port receiver_ip sender_ip sink jitter loopback
    IFS='|' read -r port receiver_ip sender_ip sink jitter loopback <<< "$form_data"
    local -a args=(--port "$port" --jitter "$jitter" --loopback "$loopback")
    [[ -z "$receiver_ip" ]] || args+=(--receiver-ip "$receiver_ip")
    [[ -z "$sender_ip" ]] || args+=(--sender-ip "$sender_ip")
    [[ "$sink" == "None" || -z "$sink" ]] || args+=(--playback-sink "$sink")
    run_session "Receiver" "$RECEIVER" "${args[@]}"
}

function run_session() {
    local label=$1
    local script=$2
    shift 2

    local runtime_dir log_file live_fifo process_id viewer_id tail_id
    runtime_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/rtp-gui.XXXXXX")"
    log_file="$runtime_dir/session.log"
    live_fifo="$runtime_dir/live.log"
    : > "$log_file"
    mkfifo "$live_fifo"

    RTP_GUI=1 "$script" "$@" >"$log_file" 2>&1 &
    process_id=$!

    yad --text-info --tail \
        --title="RTP Audio $label" \
        --width=760 --height=440 \
        --button=Stop:0 --button=Close:1 < "$live_fifo" &
    viewer_id=$!
    tail -n +1 -f "$log_file" > "$live_fifo" &
    tail_id=$!

    wait "$viewer_id" || true
    kill "$tail_id" 2>/dev/null || true
    wait "$tail_id" 2>/dev/null || true

    if kill -0 "$process_id" 2>/dev/null; then
        kill -TERM "$process_id" 2>/dev/null || true
    fi
    wait "$process_id" 2>/dev/null || true
    rm -rf -- "$runtime_dir"
}

function main() {
    require_dependencies

    local mode
    if ! mode=$(choose_mode); then
        exit 0
    fi
    mode=${mode//$'\r'/}
    while [[ "$mode" == *'|' ]]; do
        mode=${mode%|}
    done
    mode=${mode##*|}
    mode="${mode#"${mode%%[![:space:]]*}"}"
    mode="${mode%"${mode##*[![:space:]]}"}"

    case "$mode" in
        Sender) sender_form || true ;;
        Receiver) receiver_form || true ;;
        *) show_error "Unrecognized mode selection: '$mode'. Choose Sender or Receiver."; exit 1 ;;
    esac
}

main "$@"
