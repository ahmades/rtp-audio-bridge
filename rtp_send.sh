#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/rtp_common.sh"

function usage() {
    echo "Usage: $0 --source <pulse_source> [--sender-ip <ip>] --receiver-ip <ip> --port <port> [--mtu <bytes>] [--bitrate <bits/s>]"
    echo "       $0 -i <pulse_source> [-s <sender_ip>] -d <receiver_ip> -p <port> [-m <mtu>] [-b <bitrate>]"
    echo
    echo "Options:"
    echo "  -i, --source <name>          PulseAudio/PipeWire source name (mandatory)"
    echo "  -s, --sender-ip <ip>         Local IPv4 address (auto-detected if omitted)"
    echo "  -d, --receiver-ip <ip>       Receiver machine's IPv4 address (mandatory)"
    echo "  -p, --port <port>            RTP UDP port (mandatory)"
    echo "  -m, --mtu <bytes>            Maximum RTP packet size (default: 1200)"
    echo "  -b, --bitrate <bits/s>       Opus bitrate (default: 64000)"
    echo "  -h, --help                   Show this help"
    exit "${1:-0}"
}

SOURCE=""
SOURCE_IP=""
DESTINATION_IP=""
PORT=""
MTU=1200
BITRATE=64000
GST_PID=""

function parse_arguments() {
    local parsed

    if ! parsed=$(getopt -o "i:s:d:p:m:b:h" \
        -l "source:,sender-ip:,receiver-ip:,port:,mtu:,bitrate:,help" \
        -- "$@"); then
        usage 1
    fi
    eval set -- "$parsed"

    while true; do
        case "$1" in
            -i|--source) SOURCE=$2; shift 2 ;;
            -s|--sender-ip) SOURCE_IP=$2; shift 2 ;;
            -d|--receiver-ip) DESTINATION_IP=$2; shift 2 ;;
            -p|--port) PORT=$2; shift 2 ;;
            -m|--mtu) MTU=$2; shift 2 ;;
            -b|--bitrate) BITRATE=$2; shift 2 ;;
            -h|--help) usage 0 ;;
            --) shift; break ;;
        esac
    done
}

function validate_parameters() {
    [[ -n "$SOURCE" ]] || { echo "Error: -i <source> is mandatory." >&2; usage 1; }
    [[ -n "$DESTINATION_IP" ]] || { echo "Error: -d <destination_ip> is mandatory." >&2; usage 1; }
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
        echo "Error: sender IP must be a valid IPv4 address: $SOURCE_IP" >&2
        exit 1
    fi

    if ! is_ipv4 "$DESTINATION_IP"; then
        echo "Error: receiver IP must be a valid IPv4 address: $DESTINATION_IP" >&2
        exit 1
    fi
}

function check_dependencies() {
    local command

    for command in getopt pactl ip awk ping gst-launch-1.0 gst-inspect-1.0; do
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
        SOURCE_IP="$(local_ipv4_for_peer "$DESTINATION_IP")" || {
            echo "Error: could not determine the local sender IP for route to $DESTINATION_IP." >&2
            exit 1
        }
        echo "Using local sender IP: $SOURCE_IP"
    fi

    if ! is_ipv4 "$SOURCE_IP"; then
        echo "Error: sender IP must be a valid IPv4 address: $SOURCE_IP" >&2
        exit 1
    fi

    if ! local_ipv4_interface "$SOURCE_IP" >/dev/null; then
        echo "Error: sender IP is not assigned to a local interface: $SOURCE_IP" >&2
        exit 1
    fi
}

function check_remote_reachability() {
    check_ip_reachable "$SOURCE_IP" "$DESTINATION_IP"
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
    echo "Source IP:      $SOURCE_IP"
    echo "Destination IP: $DESTINATION_IP"
    echo "Port:           $PORT"
    echo "Bitrate:        $BITRATE bits/s"
    echo "RTP MTU:        $MTU bytes"

    configure_cleanup
    gst-launch-1.0 -q \
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
    echo "  Source IP:   $SOURCE_IP"
    echo "  Destination: $DESTINATION_IP:$PORT"
    echo "  Codec:       Opus at $BITRATE bits/s"
    echo "Press Ctrl-C to stop the GStreamer sender."
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