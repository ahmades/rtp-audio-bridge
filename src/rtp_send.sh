#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/rtp_common.sh"

function usage() {
    echo "Usage: $0 --source <pulse_source> [--sender-ip <sender_ipv4>] --receiver-ip <receiver_ipv4> --port <port> [--mtu <bytes>] [--bitrate <bits/s>] [--diagnostics] [--skip-reachability-check]"
    echo "       $0 -i <pulse_source> [-s <sender_ipv4>] -r <receiver_ipv4> -p <port> [-m <mtu>] [-b <bitrate>] [-d] [-S]"
    echo
    echo "Options:"
    echo "  -i, --source <name>            PulseAudio/PipeWire source name (mandatory)"
    echo "  -s, --sender-ip <ipv4>         Sender IPv4 address (auto-detected if omitted)"
    echo "  -r, --receiver-ip <ipv4>       Receiver IPv4 address (mandatory)"
    echo "  -p, --port <port>              RTP UDP port (mandatory)"
    echo "  -m, --mtu <bytes>              Maximum RTP packet size (default: 1200)"
    echo "  -b, --bitrate <bits/s>         Opus bitrate (default: 64000)"
    echo "  -d, --diagnostics              Output GStreamer bus messages"
    echo "  -S, --skip-reachability-check  Skip the ICMP ping check before starting"
    echo "  -h, --help                     Show this help"
    exit "${1:-0}"
}

SOURCE=""
SOURCE_IP=""
DESTINATION_IP=""
PORT=""
MTU=1200
BITRATE=64000
SKIP_REACHABILITY_CHECK=0
DIAGNOSTICS=0
GST_PID=""

function parse_arguments() {
    local parsed

    if ! parsed=$(getopt -o "i:s:r:p:m:b:dSh" \
        -l "source:,sender-ip:,receiver-ip:,port:,mtu:,bitrate:,diagnostics,skip-reachability-check,help" \
        -- "$@"); then
        usage 1
    fi
    eval set -- "$parsed"

    while true; do
        case "$1" in
            -i|--source) SOURCE=$2; shift 2 ;;
            -s|--sender-ip) SOURCE_IP=$2; shift 2 ;;
            -r|--receiver-ip) DESTINATION_IP=$2; shift 2 ;;
            -p|--port) PORT=$2; shift 2 ;;
            -m|--mtu) MTU=$2; shift 2 ;;
            -b|--bitrate) BITRATE=$2; shift 2 ;;
            -d|--diagnostics) DIAGNOSTICS=1; shift ;;
            -S|--skip-reachability-check) SKIP_REACHABILITY_CHECK=1; shift ;;
            -h|--help) usage 0 ;;
            --) shift; break ;;
        esac
    done
}

function validate_parameters() {
    [[ -n "$SOURCE" ]] || { echo "Error: -i <source> is mandatory." >&2; usage 1; }
    [[ -n "$DESTINATION_IP" ]] || { echo "Error: -r <receiver_ipv4> is mandatory." >&2; usage 1; }
    [[ -n "$PORT" ]] || { echo "Error: -p <port> is mandatory." >&2; usage 1; }

    if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
        echo "Error: invalid port: $PORT" >&2
        exit 1
    fi

    if [[ -n "$MTU" ]] && { ! [[ "$MTU" =~ ^[0-9]{1,5}$ ]] || (( 10#$MTU < 256 || 10#$MTU > 9000 )); }; then
        echo "Error: MTU must be an integer from 256 to 9000: $MTU" >&2
        exit 1
    fi

    if ! [[ "$BITRATE" =~ ^[0-9]{1,6}$ ]] || (( 10#$BITRATE < 6000 || 10#$BITRATE > 512000 )); then
        echo "Error: Opus bitrate must be an integer from 6000 to 512000: $BITRATE" >&2
        exit 1
    fi

    if [[ -n "$SOURCE_IP" ]] && ! is_ipv4 "$SOURCE_IP"; then
        echo "Error: sender IPv4 address is invalid: $SOURCE_IP" >&2
        exit 1
    fi

    if ! is_ipv4 "$DESTINATION_IP"; then
        echo "Error: receiver IPv4 address is invalid: $DESTINATION_IP" >&2
        exit 1
    fi
}

function check_dependencies() {
    local command

    local -a commands=(getopt pactl ip awk gst-launch-1.0 gst-inspect-1.0)
    if (( SKIP_REACHABILITY_CHECK == 0 )); then
        commands+=(ping)
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

    for element in pulsesrc audioconvert audioresample opusenc rtpopuspay udpsink; do
        if ! gst-inspect-1.0 "$element" >/dev/null 2>&1; then
            echo "Error: GStreamer element '$element' is unavailable." >&2
            exit 1
        fi
    done
}

function resolve_sender_ip() {
    if [[ -z "$SOURCE_IP" ]]; then
        SOURCE_IP="$(route_ipv4_for_peer "$DESTINATION_IP")" || {
            echo "Error: could not determine the sender IPv4 address for route to $DESTINATION_IP." >&2
            exit 1
        }
        echo "Using sender IPv4 address: $SOURCE_IP"
    fi

    if ! is_ipv4 "$SOURCE_IP"; then
        echo "Error: sender IPv4 address is invalid: $SOURCE_IP" >&2
        exit 1
    fi

    if ! interface_for_ipv4 "$SOURCE_IP" >/dev/null; then
        echo "Error: sender IPv4 address is not configured on a network interface: $SOURCE_IP" >&2
        exit 1
    fi
}

function check_remote_reachability() {
    if (( SKIP_REACHABILITY_CHECK )); then
        echo "Skipping ICMP reachability check."
    else
        check_ip_reachable "$SOURCE_IP" "$DESTINATION_IP"
    fi
}

function check_capture_source() {
    if ! pactl list short sources | awk -v source="$SOURCE" '$2 == source { found = 1 } END { exit !found }'; then
        echo "Error: PulseAudio source not found: $SOURCE" >&2
        echo "Available sources:"
        pactl list short sources
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
}

function start_sender() {
    echo "Starting Opus RTP sender..."
    echo "Source:         $SOURCE"
    echo "Sender IPv4:   $SOURCE_IP"
    echo "Receiver IPv4: $DESTINATION_IP"
    echo "Port:           $PORT"
    echo "Bitrate:        $BITRATE bits/s"
    echo "RTP MTU:        $MTU bytes"

    configure_cleanup
    local -a gst_options=()
    if (( DIAGNOSTICS )); then
        gst_options+=(--messages)
    else
        gst_options+=(-q)
    fi
    gst-launch-1.0 "${gst_options[@]}" \
        pulsesrc device="$SOURCE" \
        ! audioconvert \
        ! audioresample \
        ! audio/x-raw,rate=48000,channels=2 \
        ! opusenc bitrate="$BITRATE" \
        ! rtpopuspay mtu="$MTU" \
        ! udpsink host="$DESTINATION_IP" port="$PORT" bind-address="$SOURCE_IP" sync=false async=false &
    GST_PID=$!
}

function show_sender_status() {
    echo
    echo "=== RTP sender running ==="
    echo "  Source:      $SOURCE"
    echo "  Sender IPv4: $SOURCE_IP"
    echo "  Destination: $DESTINATION_IP:$PORT"
    echo "  Codec:       Opus at $BITRATE bits/s"
    if [[ "${RTP_GUI:-0}" != 1 ]]; then
        echo "Press Ctrl-C to stop the GStreamer sender."
    fi
}

function wait_for_sender() {
    wait "$GST_PID"
}

function main() {
    parse_arguments "$@"
    validate_parameters
    check_dependencies
    check_gstreamer_elements
    resolve_sender_ip
    check_remote_reachability
    check_capture_source
    start_sender
    show_sender_status
    wait_for_sender
}

main "$@"