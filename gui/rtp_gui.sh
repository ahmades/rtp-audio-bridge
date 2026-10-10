#!/usr/bin/env bash

set -euo pipefail

GUI_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd -- "$GUI_DIR/../src" && pwd)"
SENDER="$SRC_DIR/rtp_send.sh"
RECEIVER="$SRC_DIR/rtp_receive.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rtp-audio"
FORM_DEFAULTS=()

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

    for command in yad pactl tail mkfifo mktemp cp; do
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

function load_defaults() {
    local file=$1
    shift
    local index
    local -a saved=()

    FORM_DEFAULTS=("$@")
    if [[ -f "$file" ]]; then
        mapfile -t saved < "$file"
        for index in "${!FORM_DEFAULTS[@]}"; do
            if (( index < ${#saved[@]} )); then
                FORM_DEFAULTS[index]=${saved[index]}
            fi
        done
    fi
}

function save_defaults() {
    local file=$1
    shift
    local temporary_file

    mkdir -p -- "$CONFIG_DIR"
    temporary_file="$(mktemp "$file.XXXXXX")"
    if ! printf '%s\n' "$@" > "$temporary_file" || ! chmod 600 "$temporary_file" || ! mv -f -- "$temporary_file" "$file"; then
        rm -f -- "$temporary_file"
        show_error "Could not save the last-used form values."
        return 1
    fi
}

function combo_values() {
    awk -v prefix="$1" -v preferred="$2" '
        { values[++count] = $2 }
        END {
            found = (prefix != "" && preferred == prefix)
            for (i = 1; i <= count; i++) {
                if (values[i] == preferred) found = 1
            }
            if (!found) preferred = prefix != "" ? prefix : values[1]

            first = 1
            if (preferred != "") {
                printf "%s", preferred
                first = 0
            }
            if (prefix != "" && prefix != preferred) {
                printf "%s%s", first ? "" : "!", prefix
                first = 0
            }
            for (i = 1; i <= count; i++) {
                if (values[i] != preferred && values[i] != prefix) {
                    printf "%s%s", first ? "" : "!", values[i]
                    first = 0
                }
            }
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
    load_defaults "$CONFIG_DIR/sender.defaults" "" "" "" "4010" "1200" "64000"
    sources="$(pactl list short sources | combo_values "" "${FORM_DEFAULTS[0]}")"
    if [[ -z "$sources" ]]; then
        show_error "No PulseAudio/PipeWire sources are available."
        return 1
    fi

    if ! form_data=$(yad --form \
        --title="RTP Audio Sender" \
        --text="Send Opus audio over RTP" \
        --field="Capture source:CB" "$sources" \
        --field="Sender IPv4 (optional)" "${FORM_DEFAULTS[1]}" \
        --field="Receiver IPv4" "${FORM_DEFAULTS[2]}" \
        --field="Port" "${FORM_DEFAULTS[3]}" \
        --field="RTP MTU" "${FORM_DEFAULTS[4]}" \
        --field="Opus bitrate (bits/s)" "${FORM_DEFAULTS[5]}" \
        --width=520 --height=300 \
        --button=Cancel:1 --button=Start:0); then
        return 1
    fi

    local source sender_ip receiver_ip port mtu bitrate
    IFS='|' read -r source sender_ip receiver_ip port mtu bitrate <<< "$form_data"
    save_defaults "$CONFIG_DIR/sender.defaults" "$source" "$sender_ip" "$receiver_ip" "$port" "$mtu" "$bitrate" || true
    local -a args=(--source "$source" --receiver-ip "$receiver_ip" --port "$port" --mtu "$mtu" --bitrate "$bitrate")
    if [[ -n "$sender_ip" ]]; then
        args+=(--sender-ip "$sender_ip")
    fi
    run_session "Sender" "$SENDER" "${args[@]}"
}

function receiver_form() {
    local sinks form_data
    load_defaults "$CONFIG_DIR/receiver.defaults" "4010" "" "" "None" "200" "50"
    sinks="$(pactl list short sinks | combo_values "None" "${FORM_DEFAULTS[3]}")"

    if ! form_data=$(yad --form \
        --title="RTP Audio Receiver" \
        --text="Receive and decode Opus RTP audio" \
        --field="Port" "${FORM_DEFAULTS[0]}" \
        --field="Receiver IPv4 (optional)" "${FORM_DEFAULTS[1]}" \
        --field="Expected sender IPv4 (optional)" "${FORM_DEFAULTS[2]}" \
        --field="Playback sink:CB" "$sinks" \
        --field="Jitter buffer (ms)" "${FORM_DEFAULTS[4]}" \
        --field="Loopback latency (ms)" "${FORM_DEFAULTS[5]}" \
        --width=520 --height=300 \
        --button=Cancel:1 --button=Start:0); then
        return 1
    fi

    local port receiver_ip sender_ip sink jitter loopback
    IFS='|' read -r port receiver_ip sender_ip sink jitter loopback <<< "$form_data"
    save_defaults "$CONFIG_DIR/receiver.defaults" "$port" "$receiver_ip" "$sender_ip" "$sink" "$jitter" "$loopback" || true
    local -a args=(--port "$port" --jitter "$jitter" --loopback "$loopback")
    [[ -z "$receiver_ip" ]] || args+=(--receiver-ip "$receiver_ip")
    [[ -z "$sender_ip" ]] || args+=(--sender-ip "$sender_ip")
    [[ "$sink" == "None" || -z "$sink" ]] || args+=(--playback-sink "$sink")
    run_session "Receiver" "$RECEIVER" "${args[@]}"
}

function run_session_process() {
    local script=$1
    local log_file=$2
    local done_file=$3
    shift 3
    local child_pid status

    RTP_GUI=1 "$script" "$@" >> "$log_file" 2>&1 &
    child_pid=$!

    function stop_session_child() {
        trap - TERM INT
        kill -TERM "$child_pid" 2>/dev/null || true
        if wait "$child_pid"; then
            status=0
        else
            status=$?
        fi
        printf '\n[Stopped by user; process exit status %s.]\n' "$status" >> "$log_file"
        printf '%s\n' "$status" > "$done_file"
        exit 0
    }

    trap stop_session_child TERM INT
    if wait "$child_pid"; then
        status=0
    else
        status=$?
    fi
    printf '\n[Process exited with status %s.]\n' "$status" >> "$log_file"
    printf '%s\n' "$status" > "$done_file"
}

function copy_log() {
    local log_file=$1

    if command -v wl-copy >/dev/null 2>&1; then
        wl-copy < "$log_file"
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -in < "$log_file" >/dev/null 2>&1 &
    elif command -v xsel >/dev/null 2>&1; then
        xsel --clipboard --input < "$log_file"
    else
        show_error "Install wl-clipboard, xclip, or xsel to copy logs."
        return 1
    fi
}

function save_log() {
    local label=$1
    local log_file=$2
    local destination

    if destination=$(yad --file --save --confirm-overwrite \
        --title="Save RTP Audio Log" \
        --filename="$HOME/rtp-${label,,}.log"); then
        [[ -n "$destination" ]] || return 1
        cp -- "$log_file" "$destination" || {
            show_error "Could not save the log to '$destination'."
            return 1
        }
        printf '[Log saved to %s.]\n' "$destination" >> "$log_file"
    else
        return 1
    fi
}

function stop_session_process() {
    local process_id=$1
    local done_file=$2

    if [[ ! -f "$done_file" ]]; then
        kill -TERM "$process_id" 2>/dev/null || true
    fi
    wait "$process_id" 2>/dev/null || true
}

function run_session() {
    local label=$1
    local script=$2
    shift 2

    local runtime_dir log_file live_fifo done_file process_id viewer_id tail_id dialog_status finished=0
    runtime_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/rtp-gui.XXXXXX")"
    log_file="$runtime_dir/session.log"
    live_fifo="$runtime_dir/live.log"
    done_file="$runtime_dir/session.done"
    : > "$log_file"
    mkfifo "$live_fifo"

    run_session_process "$script" "$log_file" "$done_file" "$@" &
    process_id=$!

    while true; do
        local -a buttons=(--button="Copy log:2" --button="Save log:3" --button="Close:1")
        if [[ ! -f "$done_file" ]]; then
            buttons=(--button="Stop:0" "${buttons[@]}")
        else
            finished=1
        fi

        yad --text-info --tail \
            --title="RTP Audio $label" \
            --width=760 --height=440 \
            "${buttons[@]}" < "$live_fifo" &
        viewer_id=$!
        tail -n +1 -f "$log_file" > "$live_fifo" &
        tail_id=$!

        while kill -0 "$viewer_id" 2>/dev/null; do
            if [[ -f "$done_file" && $finished -eq 0 ]]; then
                finished=1
                kill "$tail_id" 2>/dev/null || true
                wait "$tail_id" 2>/dev/null || true
                tail_id=""
            fi
            sleep 0.1
        done

        if wait "$viewer_id"; then
            dialog_status=0
        else
            dialog_status=$?
        fi
        if [[ -n "$tail_id" ]]; then
            kill "$tail_id" 2>/dev/null || true
            wait "$tail_id" 2>/dev/null || true
        fi

        case "$dialog_status" in
            0)
                stop_session_process "$process_id" "$done_file"
                finished=1
                ;;
            2)
                if copy_log "$log_file"; then
                    printf '[Log copied to clipboard.]\n' >> "$log_file"
                fi
                ;;
            3)
                save_log "$label" "$log_file" || true
                ;;
            *)
                stop_session_process "$process_id" "$done_file"
                rm -rf -- "$runtime_dir"
                return 0
                ;;
        esac
    done
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
