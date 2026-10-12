# RTP Audio over UDP

These Bash scripts send a PulseAudio/PipeWire capture source as Opus-encoded RTP audio and expose the decoded stream as a local PulseAudio/PipeWire source. GStreamer handles capture, encoding, RTP packetization, reception, and decoding without restarting PipeWire. The transport scripts live in `src/`; `gui/rtp_gui.sh` provides an optional YAD form interface.

Keep `rtp_send.sh`, `rtp_receive.sh`, and `rtp_common.sh` together in `src/`. The scripts source the common helper from their own location, so they can be launched from another working directory.

## Requirements

- Bash
- GNU `getopt` (provided by util-linux)
- A running PulseAudio-compatible server, such as `pipewire-pulse`
- `pactl`, `ip`, `awk`, and `ping`
- `ss` on the receiver, to check local UDP port availability
- On both machines: `gst-launch-1.0`, `gst-inspect-1.0`, and GStreamer plugins providing `pulsesrc`, `opusenc`, `rtpopuspay`, `udpsink`, `udpsrc`, `rtpjitterbuffer`, `rtpopusdepay`, and `opusdec`
- On the receiver: GStreamer `audioconvert` and `filesink` elements
- The `mkfifo` utility on the receiver
- Perl on the receiver when using `--sender-ip` for packet filtering
- Optional GUI: YAD (`yad`) and a graphical desktop session

The sender and receiver must be able to exchange UDP traffic on the selected port. The receiver checks that the local UDP port is not already in use before starting. This does not verify remote firewall rules or prove that packets can reach the receiver. By default, the scripts ping their configured addresses once before starting. Use `--skip-reachability-check` when ICMP echo is blocked but UDP traffic is allowed.

## Usage

### GUI

Run `./gui/rtp_gui.sh` from the repository directory. Choose Sender or Receiver, fill in the form, and press Start. Both forms include a checkbox to skip the ICMP reachability check. The receiver form also allows a custom PulseAudio/PipeWire source name; if left blank, the current generated name is used. The GUI remembers the last submitted values for each form under `${XDG_CONFIG_HOME:-~/.config}/rtp-audio/`. The session window shows live output and the process exit status. Stop terminates the session and leaves its final log open; Close exits the log window and terminates the session if it is still running. Copy log and Save log are also available. Clipboard copying requires `wl-copy`, `xclip`, or `xsel`; saving uses YAD's file chooser. Install YAD from your distribution's package manager to use the GUI. The command-line scripts remain usable without YAD.

### Sender

```text
src/rtp_send.sh --source <pulse_source> --receiver-ip <ip> --port <port> [--sender-ip <ip>] [--mtu <bytes>] [--bitrate <bits/s>] [--skip-reachability-check]
```

The sender also accepts the corresponding short options (`-i`, `-d`, `-p`, `-s`, `-m`, and `-b`). Long options accept either `--option value` or `--option=value`.

- `-i`: capture source name from `pactl list short sources` (required).
- `-d`: receiver IPv4 address (required).
- `-p`: RTP UDP port, from 1 to 65535 (required).
- `-s`: sender's local IPv4 address. Auto-detected from the route to the receiver if omitted.
- `-m`: maximum RTP packet size in bytes, from 256 to 9000 (default: 1200).
- `-b`: Opus target bitrate in bits per second, from 6000 to 512000 (default: 64000).
- `--skip-reachability-check`: skip the startup ICMP ping checks. UDP connectivity is not tested by this option.
- `-h`: show help.

### Receiver

```text
src/rtp_receive.sh --port <port> [--receiver-ip <ip>] [--sender-ip <ip>] [--source-name <name>] [--playback-sink <name>] [--jitter <ms>] [--loopback <ms>] [--skip-reachability-check]
```

The receiver also accepts the corresponding short options (`-p`, `-d`, `-s`, `-n`, `-o`, `-j`, and `-l`). Long options accept either `--option value` or `--option=value`.

- `-p`: RTP UDP port to receive, from 1 to 65535 (required; use the same port as the sender).
- `-d`: receiver's local IPv4 address. Auto-detected from the route to `-s`, or the default route if `-s` is omitted.
- `-s`: sender IPv4 address. Incoming UDP packets from other IPv4 addresses are discarded. Filtering uses a local Perl relay; packets are still subject to normal UDP/IP spoofing risks.
- `-n`: optional PulseAudio/PipeWire source name. If omitted, the receiver generates a name from the local address, port, and optional sender address.
- `-o`: optional playback sink name from `pactl list short sinks`. When supplied, a loopback connects the RTP source to this sink.
- `-j`: jitter-buffer latency in milliseconds, from 1 to 2000 (default: 200).
- `-l`: loopback latency in milliseconds (default: 50).
- `--skip-reachability-check`: skip the startup ICMP ping checks. UDP connectivity is not tested by this option.
- `-h`: show help.

Unless `-n` is supplied, the receiver creates a PulseAudio/PipeWire source using this name pattern:

```text
rtp_receiver_${DESTINATION_IP}:${PORT}[_sender_${SOURCE_IP}]
```

For example, receiver address `198.51.100.20` and port `4010` produce `rtp_receiver_198.51.100.20:4010`. If sender address `192.0.2.10` is supplied with `-s`, the name is `rtp_receiver_198.51.100.20:4010_sender_192.0.2.10`. Select this source as an input in an audio application when `-o` is not used.

## How to Run

Start the receiver first. Replace the example port and addresses with values for your network:

The addresses below are reserved for documentation and are not routable hosts. Replace them with your machines' real local and remote IPv4 addresses before running the commands.

```bash
./src/rtp_receive.sh -p 4010 -s 192.78.2.10 -l 20 -j 300
```

Here `-s` is the sender's IPv4 address. The receiver chooses its local destination address from the route to that sender. If `-s` is omitted too, it uses the local IPv4 address selected by the default route:

```bash
./src/rtp_receive.sh -p 4010
```

Then start the sender on the other machine:

```bash
./src/rtp_send.sh -i '<capture-source-name>' -d 198.51.100.20 -p 4010
```

The sender chooses its local IPv4 address from the route to the receiver when `-s` is omitted. Supply `-s <sender-ip>` to select a particular local interface address explicitly:

```bash
./src/rtp_send.sh -i '<capture-source-name>' -s 192.78.2.10 -d 198.51.100.20 -p 4010
```

The sender's `-d` address must be the receiver machine's IPv4 address. The receiver's `-d`, when supplied, must be an IPv4 address assigned locally to the receiver. Both ends use stereo audio at 48 kHz and RTP payload type 96. The Opus bitrate is configurable on the sender; `-m` limits RTP packet size and does not set the audio bitrate.

## Stop and Troubleshoot

In the GUI, press Stop to stop the active session while keeping the final log available, or Close to close the log and stop the session if it is still running. From a terminal, press Ctrl-C. The sender stops its GStreamer pipeline. The receiver stops GStreamer, unloads its source and optional loopback modules, and removes its temporary FIFO directory.

If startup fails, verify that the chosen source or sink exists, that the PulseAudio-compatible server is running, that the receiver address is assigned locally, and that UDP traffic on the selected port can pass between the machines. By default, ICMP ping must also be permitted; pass `--skip-reachability-check` to bypass that check. The receiver's `--sender-ip` filter is an address filter, not a replacement for firewall rules.
