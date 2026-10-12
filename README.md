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
- On the receiver: GStreamer `audioconvert`, `audioresample`, and `pulsesink` elements
- PulseAudio-compatible `module-null-sink` and `module-remap-source` modules (provided by PipeWire's PulseAudio compatibility server)
- The `mkfifo` utility on the receiver when using `--sender-ip` filtering
- Perl on the receiver when using `--sender-ip` for packet filtering
- Optional GUI: YAD (`yad`) and a graphical desktop session

The sender and receiver must be able to exchange UDP traffic on the selected port. The receiver checks that the UDP port is not already in use before starting. This does not verify firewall rules or prove that packets can reach the receiver. By default, the scripts ping their configured addresses once before starting. Use `--skip-reachability-check` (or `-S`) when ICMP echo is blocked but UDP traffic is allowed.

## Usage

### GUI

Run `./gui/rtp_gui.sh` from the repository directory. Choose Sender or Receiver, fill in the form, and press Start. Both forms include a checkbox to skip the ICMP reachability check. The receiver form also allows a custom PulseAudio/PipeWire source name; if left blank, the current generated name is used. The GUI remembers the last submitted values for each form under `${XDG_CONFIG_HOME:-~/.config}/rtp-audio/`. The session window shows live output and the process exit status. Stop terminates the session and leaves its final log open; Close exits the log window and terminates the session if it is still running. Copy log and Save log are also available. Clipboard copying requires `wl-copy`, `xclip`, or `xsel`; saving uses YAD's file chooser. Install YAD from your distribution's package manager to use the GUI. The command-line scripts remain usable without YAD.

### Sender

```text
src/rtp_send.sh --source <pulse_source> --receiver-ip <receiver_ipv4> --port <port> [--sender-ip <sender_ipv4>] [--mtu <bytes>] [--bitrate <bits/s>] [--diagnostics] [--skip-reachability-check]
```

Short options: `-i` source, `-s` sender IPv4 address, `-r` receiver IPv4 address, `-p` port, `-m` MTU, `-b` bitrate, `-d` diagnostics, and `-S` skip reachability checks. Long options accept either `--option value` or `--option=value`.

- `-i`, `--source`: capture source name from `pactl list short sources` (required).
- `-r`, `--receiver-ip`: receiver IPv4 address (required).
- `-p`, `--port`: RTP UDP port, from 1 to 65535 (required).
- `-s`, `--sender-ip`: sender IPv4 address. Auto-detected from the route to the receiver if omitted.
- `-m`, `--mtu`: maximum RTP packet size in bytes, from 256 to 9000 (default: 1200).
- `-b`, `--bitrate`: Opus target bitrate in bits per second, from 6000 to 512000 (default: 64000).
- `-d`, `--diagnostics`: print GStreamer bus messages to help diagnose sender capture, encoding, and network-sink behavior.
- `-S`, `--skip-reachability-check`: skip the startup ICMP ping checks. UDP connectivity is not tested by this option.
- `-h`, `--help`: show help.

### Receiver

```text
src/rtp_receive.sh --port <port> [--receiver-ip <receiver_ipv4>] [--sender-ip <sender_ipv4>] [--source-name <name>] [--playback-sink <name>] [--jitter <ms>] [--loopback <ms>] [--sink-buffer <ms>] [--sink-latency <ms>] [--diagnostics] [--no-drop-on-latency] [--skip-reachability-check]
```

Long options accept either `--option value` or `--option=value`.

- `-p`, `--port`: RTP UDP port to receive, from 1 to 65535 (required; use the same port as the sender).
- `-r`, `--receiver-ip`: receiver IPv4 address. Auto-detected from the route to `-s`/`--sender-ip`, or the default route if the sender address is omitted.
- `-s`, `--sender-ip`: sender IPv4 address. Incoming UDP packets from other IPv4 addresses are discarded. Filtering uses a local Perl relay; packets are still subject to normal UDP/IP spoofing risks.
- `-n`, `--source-name`: optional friendly label for the exposed RTP input source. Pavucontrol displays the exact name supplied. If omitted, the receiver generates a label from the receiver IPv4 address, port, and optional sender IPv4 address.
- `-o`, `--playback-sink`: optional playback sink name from `pactl list short sinks`. When supplied, a loopback connects the RTP source to this sink.
- `-j`, `--jitter`: jitter-buffer latency in milliseconds, from 1 to 2000 (default: 200).
- `-l`, `--loopback`: loopback latency in milliseconds (default: 50).
- `-B`, `--sink-buffer`: PulseAudio sink buffer in milliseconds, from 1 to 1000 (default: 50).
- `-L`, `--sink-latency`: PulseAudio sink write latency in milliseconds, from 1 to 100 and no greater than `--sink-buffer`/`-B` (default: 5).
- `-d`, `--diagnostics`: print GStreamer bus messages and jitter-buffer packet-drop reports without changing pipeline latency or drop policy.
- `-N`, `--no-drop-on-latency`: disable the jitter buffer's latency cap. This can reduce drops caused by packet bursts, but queued audio and playback latency may grow; use with `--diagnostics`/`-d` to compare.
- `-S`, `--skip-reachability-check`: skip the startup ICMP ping checks. UDP connectivity is not tested by this option.
- `-h`, `--help`: show help.

The receiver exposes a remapped input source. Unless `-n` is supplied, its friendly label uses this pattern:

```text
rtp_receiver_${DESTINATION_IP}:${PORT}[_sender_${SOURCE_IP}]
```

For example, receiver address `198.51.100.20` and port `4010` produce the input name `rtp_receiver_198.51.100.20:4010`. If sender address `192.0.2.10` is supplied with `-s`, the name is `rtp_receiver_198.51.100.20:4010_sender_192.0.2.10`. The null sink's separate monitor is only the internal backing source; select the named RTP input in an audio application when `-o` is not used.

## How to Run

Start the receiver first. Replace the example port and addresses with values for your network:

The addresses below are reserved for documentation and are not routable hosts. Replace them with the sender and receiver IPv4 addresses for your network before running the commands.

```bash
./src/rtp_receive.sh -p 4010 -s 192.78.2.10 -l 20 -j 300
```

Here `-s` is the sender IPv4 address. The receiver determines its receiver IPv4 address from the route to that sender. If `-s` is omitted too, it uses the receiver IPv4 address selected by the default route:

```bash
./src/rtp_receive.sh -p 4010
```

Then start the sender on the other machine:

```bash
./src/rtp_send.sh -i '<capture-source-name>' -r 198.51.100.20 -p 4010
```

The sender determines its sender IPv4 address from the route to the receiver when `-s` is omitted. Supply `-s <sender-ip>` to select a specific sender IPv4 address:

```bash
./src/rtp_send.sh -i '<capture-source-name>' -s 192.78.2.10 -r 198.51.100.20 -p 4010
```

The sender's `-r` value must be the receiver IPv4 address. The receiver's `-r`, when supplied, must be an IPv4 address assigned to the receiver machine. Both ends use stereo audio at 48 kHz and RTP payload type 96. The Opus bitrate is configurable on the sender; `-m` limits RTP packet size and does not set the audio bitrate.

## Stop and Troubleshoot

In the GUI, press Stop to stop the active session while keeping the final log available, or Close to close the log and stop the session if it is still running. From a terminal, press Ctrl-C. The sender stops its GStreamer pipeline. The receiver stops GStreamer and unloads its null sink, optional loopback, and sender-filter resources.

If startup fails, verify that the chosen source or sink exists, that the PulseAudio-compatible server is running, that the receiver IPv4 address is configured on the receiver machine, and that UDP traffic on the selected port can pass between the machines. By default, ICMP ping must also be permitted; pass `--skip-reachability-check` or `-S` to bypass that check. The receiver's `--sender-ip` filter is an address filter, not a replacement for firewall rules.
