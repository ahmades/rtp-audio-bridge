#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/rtp_common.sh"

function usage() {
    echo "Usage: $0 --port <port> [--receiver-ip <ip>] [--sender-ip <ip>] [--source-name <name>] [--playback-sink <name>] [--jitter <ms>] [--loopback <ms>] [--skip-reachability-check]"
    echo "       $0 [-d <receiver_ip>] -p <port> [-s <sender_ip>] [-n <source_name>] [-o <playback_sink>] [-j <jitter_ms>] [-l <loopback_ms>] [--skip-reachability-check]"
    echo
    echo "Receives the sender's Opus RTP audio without restarting PipeWire."
    echo "Options:"
    echo "  -d, --receiver-ip <ip>       Local IPv4 address (auto-detected if omitted)"
    echo "  -p, --port <port>            RTP UDP port to receive (mandatory)"
    echo "  -s, --sender-ip <ip>         Filter packets to this sender IPv4 address"
    echo "  -n, --source-name <name>     PulseAudio/PipeWire source name (generated if omitted)"
    echo "  -o, --playback-sink <name>   Optional PulseAudio/PipeWire playback sink"
    echo "  -j, --jitter <ms>            RTP jitter buffer (default: 200)"
    echo "  -l, --loopback <ms>          Playback loopback latency (default: 50)"
    echo "      --skip-reachability-check Skip the ICMP ping check before starting"
    echo "  -h, --help                   Show this help"
    echo
    echo "When --sender-ip is set, packets from other IPv4 addresses are discarded."
    exit "${1:-0}"
}

SOURCE_IP=""
DESTINATION_IP=""
PORT=""
JITTER_MS=200
LOOPBACK_MS=50
PLAYBACK_SINK=""
CUSTOM_SOURCE_NAME=""
SKIP_REACHABILITY_CHECK=0
LOCAL_IFNAME=""
RUNTIME_DIR=""
FIFO=""
FILTER_FIFO=""
SOURCE_NAME=""
SOURCE_MODULE_ID=""
LOOPBACK_MODULE_ID=""
GST_PID=""
FILTER_PID=""
RELAY_PORT=""
FILTER_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/rtp_udp_filter.pl"

function parse_arguments() {
    local parsed

    if ! parsed=$(getopt -o "s:d:p:o:j:l:n:h" \
        -l "sender-ip:,receiver-ip:,port:,playback-sink:,jitter:,loopback:,source-name:,skip-reachability-check,help" \
        -- "$@"); then
        usage 1
    fi
    eval set -- "$parsed"

    while true; do
        case "$1" in
            -s|--sender-ip) SOURCE_IP=$2; shift 2 ;;
            -d|--receiver-ip) DESTINATION_IP=$2; shift 2 ;;
            -p|--port) PORT=$2; shift 2 ;;
            -o|--playback-sink) PLAYBACK_SINK=$2; shift 2 ;;
            -j|--jitter) JITTER_MS=$2; shift 2 ;;
            -l|--loopback) LOOPBACK_MS=$2; shift 2 ;;
            -n|--source-name) CUSTOM_SOURCE_NAME=$2; shift 2 ;;
            --skip-reachability-check) SKIP_REACHABILITY_CHECK=1; shift ;;
            -h|--help) usage 0 ;;
            --) shift; break ;;
        esac
    done
}

function validate_parameters() {
    [[ -n "$PORT" ]] || { echo "Error: -p <port> is mandatory." >&2; usage 1; }

    if [[ -n "$SOURCE_IP" ]] && ! is_ipv4 "$SOURCE_IP"; then
        echo "Error: invalid sender IPv4 address: $SOURCE_IP" >&2
        exit 1
    fi

    if [[ -n "$DESTINATION_IP" ]] && ! is_ipv4 "$DESTINATION_IP"; then
        echo "Error: invalid receiver IPv4 address: $DESTINATION_IP" >&2
        exit 1
    fi

    if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
        echo "Error: invalid port: $PORT" >&2
        exit 1
    fi
    PORT=$((10#$PORT))

    if ! [[ "$JITTER_MS" =~ ^[0-9]+$ ]] || (( JITTER_MS < 1 || JITTER_MS > 2000 )); then
        echo "Error: jitter buffer must be an integer from 1 to 2000 ms: $JITTER_MS" >&2
        exit 1
    fi

    if ! [[ "$LOOPBACK_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "Error: invalid loopback latency: $LOOPBACK_MS" >&2
        exit 1
    fi
}

function check_dependencies() {
    local command

    local -a commands=(getopt ip awk pactl gst-launch-1.0 gst-inspect-1.0 mkfifo ss)
    if (( SKIP_REACHABILITY_CHECK == 0 )); then
        commands+=(ping)
    fi
    if [[ -n "$SOURCE_IP" ]]; then
        commands+=(perl)
    fi
    for command in "${commands[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "Error: '$command' is not installed." >&2
            exit 1
        fi
    done

    if ! pactl info >/dev/null 2>&1; then
        echo "Error: cannot connect to the PulseAudio-compatible server (pipewire-pulse)." >&2
        exit 1
    fi
}

function check_gstreamer_elements() {
    local element

    for element in udpsrc rtpjitterbuffer rtpopusdepay opusdec audioconvert filesink; do
        if ! gst-inspect-1.0 "$element" >/dev/null 2>&1; then
            echo "Error: GStreamer element '$element' is unavailable." >&2
            exit 1
        fi
    done
}

function resolve_local_interface() {
    if [[ -z "$DESTINATION_IP" ]]; then
        DESTINATION_IP="$(local_ipv4_for_peer "$SOURCE_IP")" || {
            echo "Error: could not determine the local receiver IP from the routing table." >&2
            exit 1
        }
        echo "Using local receiver IP: $DESTINATION_IP"
    fi

    if ! is_ipv4 "$DESTINATION_IP"; then
        echo "Error: invalid receiver IPv4 address: $DESTINATION_IP" >&2
        exit 1
    fi

    LOCAL_IFNAME="$(local_ipv4_interface "$DESTINATION_IP")"
    if [[ -z "$LOCAL_IFNAME" ]]; then
        echo "Error: receiver IP is not assigned to a local interface: $DESTINATION_IP" >&2
        exit 1
    fi
}

function check_udp_port_available() {
    local sockets

    if ! sockets="$(ss -H -lun "sport = :$PORT")"; then
        echo "Error: could not check whether UDP port $PORT is available." >&2
        exit 1
    fi

    if [[ -n "$sockets" ]]; then
        echo "Error: UDP port $PORT is already in use on this machine:" >&2
        echo "$sockets" >&2
        exit 1
    fi
}

function check_reachable_ips() {
    if (( SKIP_REACHABILITY_CHECK )); then
        echo "Skipping ICMP reachability check."
    else
        check_ip_reachable "$DESTINATION_IP" "$SOURCE_IP"
    fi
}

function check_playback_sink() {
    if [[ -n "$PLAYBACK_SINK" ]] && ! pactl list short sinks | awk -v sink="$PLAYBACK_SINK" '$2 == sink { found = 1 } END { exit !found }'; then
        echo "Error: playback sink not found: $PLAYBACK_SINK" >&2
        echo "Available sinks:"
        pactl list short sinks
        exit 1
    fi
}

function configure_cleanup() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

function cleanup() {
    trap - EXIT INT TERM
    if [[ -n "$GST_PID" ]]; then
        kill "$GST_PID" >/dev/null 2>&1 || true
        wait "$GST_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$FILTER_PID" ]]; then
        kill "$FILTER_PID" >/dev/null 2>&1 || true
        wait "$FILTER_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$LOOPBACK_MODULE_ID" ]]; then
        pactl unload-module "$LOOPBACK_MODULE_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SOURCE_MODULE_ID" ]]; then
        pactl unload-module "$SOURCE_MODULE_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$RUNTIME_DIR" ]]; then
        rm -rf -- "$RUNTIME_DIR"
    fi
}

function create_runtime_fifo() {
    RUNTIME_DIR="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/rta-rtp-receiver.XXXXXX")"
    FIFO="$RUNTIME_DIR/audio.pcm"
    if [[ -n "$CUSTOM_SOURCE_NAME" ]]; then
        SOURCE_NAME="$CUSTOM_SOURCE_NAME"
    else
        SOURCE_NAME="rtp_receiver_${DESTINATION_IP}:${PORT}"
        if [[ -n "$SOURCE_IP" ]]; then
            SOURCE_NAME+="_sender_${SOURCE_IP}"
        fi
    fi
    if [[ -n "$SOURCE_IP" ]]; then
        FILTER_FIFO="$RUNTIME_DIR/filter-ready"
        mkfifo "$FILTER_FIFO"
    fi
    mkfifo "$FIFO"
}

function start_udp_filter() {
    local ready_status

    perl "$FILTER_HELPER" "$DESTINATION_IP" "$PORT" "$SOURCE_IP" "$FILTER_FIFO" &
    FILTER_PID=$!
    IFS= read -r ready_status < "$FILTER_FIFO"
    if [[ "$ready_status" == ERROR:* ]]; then
        echo "Error: ${ready_status#ERROR: }" >&2
        wait "$FILTER_PID" || true
        FILTER_PID=""
        return 1
    fi
    if ! [[ "$ready_status" =~ ^[0-9]+$ ]] || (( ready_status < 1 || ready_status > 65535 )); then
        echo "Error: UDP source filter returned an invalid relay port." >&2
        return 1
    fi
    RELAY_PORT=$ready_status
}

function start_gstreamer_receiver() {
    local receive_address="$DESTINATION_IP"
    local receive_port="$PORT"

    if [[ -n "$SOURCE_IP" ]]; then
        start_udp_filter
        receive_address="127.0.0.1"
        receive_port="$RELAY_PORT"
    fi

    gst-launch-1.0 -q \
        udpsrc address="$receive_address" port="$receive_port" \
            caps='application/x-rtp,media=(string)audio,clock-rate=(int)48000,encoding-name=(string)OPUS,payload=(int)96' \
        ! rtpjitterbuffer latency="$JITTER_MS" drop-on-latency=true do-lost=true \
        ! rtpopusdepay \
        ! opusdec \
        ! audioconvert \
        ! audio/x-raw,format=S16BE,rate=48000,channels=2 \
        ! filesink location="$FIFO" &
    GST_PID=$!
}

function load_pipe_source() {
    SOURCE_MODULE_ID="$(pactl load-module module-pipe-source \
        "file=$FIFO" \
        "source_name=$SOURCE_NAME" \
        "format=s16be" \
        "rate=48000" \
        "channels=2")"
}

function load_playback_loopback() {
    if [[ -n "$PLAYBACK_SINK" ]]; then
        LOOPBACK_MODULE_ID="$(pactl load-module module-loopback \
            "source=$SOURCE_NAME" \
            "sink=$PLAYBACK_SINK" \
            "latency_msec=$LOOPBACK_MS")"
    fi
}

function show_receiver_status() {
    echo "Creating live RTP source on $DESTINATION_IP:$PORT (interface $LOCAL_IFNAME)..."
    echo "RTP source: $SOURCE_NAME (module $SOURCE_MODULE_ID)"
    echo "Jitter buffer: ${JITTER_MS} ms (drops stale data to stay bounded)"
    if [[ -n "$SOURCE_IP" ]]; then
        echo "Filtered sender: $SOURCE_IP"
    fi

    if [[ -n "$PLAYBACK_SINK" ]]; then
        echo "Playback sink: $PLAYBACK_SINK (loopback latency ${LOOPBACK_MS} ms)"
    else
        echo "Select $SOURCE_NAME as an input source in an audio application."
    fi
    if [[ "${RTP_GUI:-0}" != 1 ]]; then
        echo "Press Ctrl-C to unload the source and stop receiving."
    fi
}

function wait_for_receiver() {
    while kill -0 "$GST_PID" 2>/dev/null; do
        sleep 1
    done

    wait "$GST_PID"
}

function main() {
    parse_arguments "$@"
    validate_parameters
    check_dependencies
    check_gstreamer_elements
    resolve_local_interface
    check_udp_port_available
    check_reachable_ips
    check_playback_sink
    configure_cleanup
    create_runtime_fifo
    start_gstreamer_receiver
    load_pipe_source
    load_playback_loopback
    show_receiver_status
    wait_for_receiver
}

main "$@"