# RTP Audio over UDP

These Bash scripts send a PulseAudio/PipeWire capture source as Opus-encoded RTP audio and expose the decoded stream as a local PulseAudio/PipeWire source. GStreamer handles capture, encoding, RTP packetization, reception, and decoding without restarting PipeWire.

Keep `rtp_send.sh`, `rtp_receive.sh`, and `rtp_common.sh` together in the same directory. The scripts source the common helper from their own location, so they can be launched from another working directory.

## Requirements

- Bash
- GNU `getopt` (provided by util-linux)
- A running PulseAudio-compatible server, such as `pipewire-pulse`
- `pactl`, `ip`, `awk`, and `ping`
- On both machines: `gst-launch-1.0`, `gst-inspect-1.0`, and GStreamer plugins providing `pulsesrc`, `opusenc`, `rtpopuspay`, `udpsink`, `udpsrc`, `rtpjitterbuffer`, `rtpopusdepay`, and `opusdec`
- On the receiver: GStreamer `audioconvert` and `filesink` elements
- The `mkfifo` utility on the receiver

The sender and receiver must be able to exchange UDP traffic on the selected port. The scripts also ping their configured addresses once before starting. ICMP echo must be permitted; a firewall that blocks ping can cause startup to fail even when the RTP/UDP path would otherwise work.

## Usage

### Sender

```text
rtp_send.sh --source <pulse_source> --receiver-ip <ip> --port <port> [--sender-ip <ip>] [--mtu <bytes>] [--bitrate <bits/s>]
```

The sender also accepts the corresponding short options (`-i`, `-d`, `-p`, `-s`, `-m`, and `-b`). Long options accept either `--option value` or `--option=value`.

- `-i`: capture source name from `pactl list short sources` (required).
- `-d`: receiver IPv4 address (required).
- `-p`: RTP UDP port, from 1 to 65535 (required).
- `-s`: sender's local IPv4 address. Auto-detected from the route to the receiver if omitted.
- `-m`: maximum RTP packet size in bytes, from 256 to 9000 (default: 1200).
- `-b`: Opus target bitrate in bits per second, from 6000 to 512000 (default: 64000).
- `-h`: show help.

### Receiver

```text
rtp_receive.sh --port <port> [--receiver-ip <ip>] [--sender-ip <ip>] [--playback-sink <name>] [--jitter <ms>] [--loopback <ms>]
```

The receiver also accepts the corresponding short options (`-p`, `-d`, `-s`, `-o`, `-j`, and `-l`). Long options accept either `--option value` or `--option=value`.

- `-p`: RTP UDP port to receive, from 1 to 65535 (required; use the same port as the sender).
- `-d`: receiver's local IPv4 address. Auto-detected from the route to `-s`, or the default route if `-s` is omitted.
- `-s`: expected sender IPv4 address. Used for address selection and reachability checking only; it does not filter incoming RTP packets.
- `-o`: optional playback sink name from `pactl list short sinks`. When supplied, a loopback connects the RTP source to this sink.
- `-j`: jitter-buffer latency in milliseconds, from 1 to 2000 (default: 200).
- `-l`: loopback latency in milliseconds (default: 50).
- `-h`: show help.

The receiver creates a PulseAudio/PipeWire source using this name pattern:

```text
rtp_receiver_${DESTINATION_IP}:${PORT}_sender_${SOURCE_IP}
```

For example, receiver address `198.51.100.20`, port `4010`, and sender address `192.0.2.10` produce `rtp_receiver_198.51.100.20:4010_sender_192.0.2.10`. If `-s` is omitted, the sender-address portion is empty. Select this source as an input in an audio application when `-o` is not used.

## How to Run

Start the receiver first. Replace the example port and addresses with values for your network:

The addresses below are reserved for documentation and are not routable hosts. Replace them with your machines' real local and remote IPv4 addresses before running the commands.

```bash
./rtp_receive.sh -p 4010 -s 192.78.2.10 -l 20 -j 300
```

Here `-s` is the sender's IPv4 address. The receiver chooses its local destination address from the route to that sender. If `-s` is omitted too, it uses the local IPv4 address selected by the default route:

```bash
./rtp_receive.sh -p 4010
```

Then start the sender on the other machine:

```bash
./rtp_send.sh -i '<capture-source-name>' -d 198.51.100.20 -p 4010
```

The sender chooses its local IPv4 address from the route to the receiver when `-s` is omitted. Supply `-s <sender-ip>` to select a particular local interface address explicitly:

```bash
./rtp_send.sh -i '<capture-source-name>' -s 192.78.2.10 -d 198.51.100.20 -p 4010
```

The sender's `-d` address must be the receiver machine's IPv4 address. The receiver's `-d`, when supplied, must be an IPv4 address assigned locally to the receiver. Both ends use stereo audio at 48 kHz and RTP payload type 96. The Opus bitrate is configurable on the sender; `-m` limits RTP packet size and does not set the audio bitrate.

## Stop and Troubleshoot

Press Ctrl-C in either terminal to stop the script. The sender stops its GStreamer pipeline. The receiver stops GStreamer, unloads its source and optional loopback modules, and removes its temporary FIFO directory.

If startup fails, verify that the chosen source or sink exists, that the PulseAudio-compatible server is running, that the receiver address is assigned locally, that ICMP ping is permitted, and that UDP traffic on the selected port can pass between the machines. The receiver does not filter packets by sender IP; use a firewall if source filtering is required.
