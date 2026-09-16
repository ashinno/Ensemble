# Ensemble

Play the audio of one Mac through the speakers of several Macs on the same Wi‑Fi/LAN, in sync.
Think of it as a small, personal Airfoil: one Mac is the **host** (the source), the others are
**receivers**. Anything the host plays (Spotify, Apple Music, YouTube, VLC, Chrome, system
sounds) is captured, streamed over the local network and played back on every connected Mac
at the same instant.

* Native macOS app, Swift + SwiftUI, Apple Silicon first. Requires **macOS 15 or newer**.
* System audio capture through a Core Audio **process tap** (no cable, no virtual audio driver,
  no microphone).
* Automatic discovery over Bonjour; one click to connect. Manual IP entry as a fallback.
* UDP audio stream with sequence numbers and host timestamps, NTP‑style clock synchronization,
  jitter buffers, continuous drift correction, three latency modes and per‑receiver controls.
* Pairing code or manual approval of each receiver; only local‑network devices are accepted.
* Built‑in diagnostics and an audible synchronization test.

---

## 1. Build

Requirements: Xcode 16 or newer (built and tested with Xcode 26.3 on macOS 27), an Apple
Silicon Mac. The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
the generated `Ensemble.xcodeproj` is included, so XcodeGen is only needed if you add files.

Open `Ensemble.xcodeproj` in Xcode and press **Run**, or from the terminal:

```bash
xcodebuild -project Ensemble.xcodeproj -scheme Ensemble -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY="-" build
```

The app is at `build/Build/Products/Debug/Ensemble.app`.

### Installing on the second Mac

Build a Release copy, ad‑hoc signed and zipped, with one command:

```bash
./scripts/make-dist.sh
```

That writes `dist/Ensemble-<version>.zip`. Then, on the other Mac:

1. AirDrop (or copy) the zip and double‑click it to unzip.
2. Drag `Ensemble.app` to `/Applications`.
3. First launch only: right‑click → **Open** and confirm. The build is ad‑hoc signed, not
   notarized, so Gatekeeper asks once. If it refuses outright, clear the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Ensemble.app
   ```
4. Open it, choose **Receiver**, and the host appears within a few seconds. Allow the Local
   Network prompt when it comes up.

Both Macs must run macOS 15 or newer on Apple Silicon (the build is arm64 only).

If you change `project.yml` or add files outside Xcode:

```bash
xcodegen generate
```

## 2. First run: permissions

### Host Mac — System Audio Recording

| | |
|---|---|
| **Permission** | *System Audio Recording Only* (a sub‑category of *Screen & System Audio Recording*) |
| **Why macOS asks** | Capturing what other apps are playing is treated like recording your screen: any app that can hear your system audio could record calls, videos and music. macOS therefore requires explicit, per‑app consent. Ensemble uses `AudioHardwareCreateProcessTap` (a Core Audio process tap), which only needs the audio‑only permission, not full screen recording, and it never touches the microphone. |
| **When** | The first time you press **Start Broadcasting**, macOS shows *"Ensemble would like to record this computer's audio"*. Click **Allow**. |
| **Where to enable manually** | System Settings → Privacy & Security → **Screen & System Audio Recording** → *System Audio Recording Only* → turn on **Ensemble**. The *Open Privacy Settings* button in the app takes you there. |

If the level meter stays flat while music is playing, the permission was denied: enable it in
System Settings, then stop and start broadcasting again (macOS may also ask you to quit and
reopen the app).

### All Macs — Local Network

macOS 15+ asks *"Ensemble would like to find and connect to devices on your local network"*
the first time the app browses for or advertises a host. Click **Allow**. If you declined, turn
it on under System Settings → Privacy & Security → **Local Network** → Ensemble.

### Firewall

If the macOS firewall is on, the host Mac will ask *"Do you want the application Ensemble to
accept incoming network connections?"* — click **Allow**. Ensemble listens on two random
ports (TCP for control, UDP for audio); the host UI shows them under *Security*.

### App icon

The icon (`Ensemble/Resources/Assets.xcassets/AppIcon.appiconset`) is generated from
`design/icon-1024.png`; `design/Ensemble.icns` is the same icon as a single file if you need it
elsewhere.

## 3. Using it

**Host Mac**

1. Open Ensemble, keep **Host** selected.
2. Choose how *this Mac's speakers* should behave:
   * **Synchronized** (default) – the tapped apps are muted at the speaker and Ensemble replays
     the captured audio itself with the same delay as the receivers. All Macs play in sync.
   * **Direct (no delay)** – this Mac plays instantly, receivers lag by the playback delay.
   * **Off** – only the receivers play.
3. Pick a latency mode (see §5) and press **Start Broadcasting**.
4. Play anything. The level meter should move.
5. Note the 4‑digit **pairing code**.

**Receiver Mac(s)**

1. Open Ensemble, choose **Receiver**. The host appears under *Available hosts* within a few
   seconds.
2. Type the pairing code (or leave it blank and click **Allow** on the host when the Mac appears
   under *Connected speakers*).
3. Click **Connect**. Status goes *Connecting → Connected → Receiving audio*; the clock syncs in
   about a second.
4. Adjust the volume slider (the host can also set each receiver's volume).

To verify alignment press **Clock click** or **Stream click** on the host and listen: one crisp
click means the Macs are aligned, a double click or an echo means they are not (see §7).

### Launch arguments (testing from a terminal)

```
Ensemble.app/Contents/MacOS/Ensemble -mode host -autostart YES -source tone -tcpPort 5555 -udpPort 5556 -pairing 1234
Ensemble.app/Contents/MacOS/Ensemble -mode receiver -autostart YES -connect 192.168.1.10:5555 -pairing 1234
```

`-source tone` streams a synthetic 440 Hz tone with a click every second instead of system
audio (no permission needed). `-localPlayback synchronized|direct|off`, `-name "Name"` and
`-verbose` are also available. Logs go to stdout and to the unified log (subsystem
`com.ashinno.ensemble`).

### Interface

The window is a grid of modules in the style of the "Modular v3" design canvas: a master strip
with the live waveform (the accent line marks what is leaving the speakers right now, i.e. the
playback delay behind the newest audio), then one module per concern — This Mac, Sync, one card
per speaker, pending approvals, Pairing, Delay, Click test, Network on the host; Volume, Sync,
Fine‑tune, Delay, Hosts nearby, Pairing, Stream, Host clock, Diagnostics on the receiver. The
four dots in the title bar switch the accent colour. **Diagnostics** / **Open** on the last
module opens the full statistics and event log.

## 4. Architecture

```
Host Mac                                                    Receiver Mac
─────────────────────────────────────────────────────────   ─────────────────────────────────────────
Spotify / Chrome / … ─┐                                     
                      ▼                                     
   Core Audio process tap (muted-when-tapped)               
   AudioCaptureManager ──► PacketChunker (10 ms, int16)     
          │                      │                          
          │                      ├─► HostStreamServer ── UDP audio ───────► ReceiverClient
          │                      │         ▲  ▲                                  │
          │                      │         │  └─ UDP clock ping/pong ◄──► ClockSyncManager
          │                      │         └──── TCP control (hello, pairing,     │
          │                      │               latency, volume, stats, sync)    ▼
          │                      ▼                                        AudioPlaybackManager
          └──────────► AudioPlaybackManager (offset 0)                    JitterBuffer + TimelineMapping
                       host's own speakers, same delay                    + DriftController → AVAudioEngine
```

| Module | File | Role |
|---|---|---|
| `AudioCaptureManager` | `Audio/AudioCaptureManager.swift` | Creates a global Core Audio process tap (excluding Ensemble's own processes), wraps it in a private aggregate device on the default output, and receives the mixed system audio in an IO proc. Rebuilds itself when the default output device changes. |
| `PacketChunker` / `TestToneSource` | `Audio/AudioSource.swift` | Splits captured float audio into 5 ms, 16‑bit packets with continuous host timestamps; synthetic test source. |
| `AudioPacket` / `UDPMessage` | `Network/AudioPacket.swift` | Binary UDP wire format: magic, type, channels, frame count, sample rate, **sequence number**, **capture timestamp (ns)**, PCM. Also clock ping/pong and hello/ack. |
| `ControlMessage` | `Network/ControlMessage.swift` | Length‑prefixed JSON over TCP: hello/pairing, welcome, pending/rejected, set latency/volume, sync test, receiver stats. |
| `HostStreamServer` | `Network/HostStreamServer.swift` | TCP listener (advertised via Bonjour `_ensemble._tcp`), UDP listener, receiver sessions, pairing/approval, clock‑sync responder, broadcast. |
| `ReceiverClient` | `Network/ReceiverClient.swift` | Connects to a host, opens the UDP flow, runs clock sync, feeds the player, reports stats once per second. |
| `BonjourDiscoveryService` | `Network/BonjourDiscoveryService.swift` | `NWBrowser` for hosts. |
| `ClockSyncManager` | `Sync/ClockSyncManager.swift` | NTP‑style offset/RTT estimation (burst of 10 pings, then 1/s; median of the lowest‑RTT quarter of a 32‑sample window). |
| `JitterBuffer` | `Audio/JitterBuffer.swift` | Ring buffer addressed by absolute stream position; zero‑fills gaps; linear‑interpolating fractional reader for rate correction. |
| `TimelineMapping`, `DriftController`, `LatencyMode` | `Sync/LatencyController.swift` | Maps stream positions to host time, converts position error into a gentle rate correction (≤ ±0.4 %) or a hard resync (> 50 ms), latency presets. |
| `AudioPlaybackManager` | `Audio/AudioPlaybackManager.swift` | `AVAudioEngine` + `AVAudioSourceNode`; each render callback works out which stream position must leave the speaker *now* and steers the read pointer; handles output‑device changes, renders sync‑test clicks. |
| `DeviceManager` | `Audio/DeviceManager.swift` | Core Audio HAL helpers (default output device, process objects, listeners). |
| `HostClock` | `Support/HostClock.swift` | `mach_absolute_time` in nanoseconds. |
| `HostController`, `ReceiverController` | `Controllers/` | `@MainActor` view models gluing the above to SwiftUI. |

### How synchronization works

1. **Timestamps.** Every packet carries the host‑clock time (`mach_absolute_time`, ns) at which its
   first frame was captured, taken from Core Audio's own input timestamp so it follows the audio
   device's clock precisely.
2. **Clock offset.** Each receiver continuously measures its clock offset to the host over UDP
   (`offset = ((t1−t2)+(t4−t3))/2`). Only the lowest‑round‑trip samples are trusted, so Wi‑Fi
   jitter is filtered out; typical accuracy on a LAN is well under a millisecond.
3. **Playback target.** A packet captured at host time *T* must leave every speaker at
   *T + delay*, where *delay* is the latency mode (60/150/400 ms or custom). In the render
   callback the receiver takes the output timestamp Core Audio provides for the buffer it is
   filling, adds the output device's presentation latency, converts it to host time using the
   offset, subtracts the delay, and asks the timeline mapping which stream position that is.
4. **Jitter buffer.** Packets are written into a ring buffer at their stream position as soon as
   they arrive; the reader trails the writer by the playback delay, which absorbs network jitter.
   Lost packets leave a zero‑filled (silent) gap; late packets that still fit in the window are
   used.
5. **Drift correction.** The difference between the ideal position and the actual read pointer
   is fed to a controller that changes the playback rate by at most ±0.4 % (inaudible) so
   sample‑clock differences between machines are cancelled continuously. Errors above 50 ms
   (e.g. after a stall or when the host restarts capture) trigger an immediate resync.
6. **The host's own speakers** run the identical player with a clock offset of zero, so they line
   up with the receivers; the tap's *mute when tapped* mode silences the original playback.

### Protocol summary

* Bonjour `_ensemble._tcp` advertises the control port.
* Receiver → host TCP `hello(name, pairingCode)`; host answers `welcome(sessionToken, udpPort, …)`
  or `pending` (until you click Allow) or `rejected`.
* Receiver opens a UDP flow to `udpPort` and sends `hello(token)`; the host binds that flow to
  the session and answers `helloAck`. From then on audio flows host → receiver on that flow, and
  clock pings flow receiver → host → receiver on it (they double as keep‑alives; 10 s of silence
  drops the receiver).
* Only endpoints in private/link‑local/loopback ranges are accepted.

## 5. Latency modes

| Mode | Delay | Use |
|---|---|---|
| Auto (default) | measured | Every receiver reports the delay it needs (99th percentile of capture→arrival time over the last 10 s, plus its output latency and a 15 ms margin). The host follows the slowest one: it raises within 2 s when audio starts arriving late and lowers in 20 ms steps after 10 s of clear headroom. Every change is a simultaneous jump on all Macs, so they never drift apart while adapting. Floor 40 ms. |
| Low latency | 60 ms | Video on the host in *Direct* mode, quiet wired/5 GHz networks. May drop out on busy Wi‑Fi. |
| Balanced | 150 ms | Music on a normal Wi‑Fi network. Default. |
| Maximum synchronization | 400 ms | Congested Wi‑Fi, Bluetooth speakers on receivers, many receivers. |
| Custom | 30–1000 ms | Anything else. |

Where the time goes on a wired network (Auto typically settles at 40–60 ms): capture IO buffer
≈3 ms (128 frames), packetising 5 ms, network 1–3 ms, receiver output buffer ≈3 ms, plus the
15 ms safety margin. On Wi‑Fi the receiving Mac's power‑save bursts dominate (see §7).

The delay is the time between the host *capturing* a sample and every Mac *playing* it. In
*Synchronized* local mode the host's own speakers are delayed by the same amount, so video on
the host will be out of lip‑sync by that amount; use *Direct* mode for video and accept that the
receivers trail.

## 6. Diagnostics

Both views have a **Diagnostics** disclosure showing: round‑trip network latency, network jitter,
estimated clock offset, clock ping/pong counts, buffer level, target delay, playback drift error,
current rate correction (ppm), output latency, packets received/lost, underruns (render callbacks
that ran out of audio), resyncs (hard jumps), and an event log. The host row for each receiver
shows latency, quality (loss % and jitter), buffer, drift and clock state, and the receivers
report these once per second.

## 7. Troubleshooting

**"Could not create the system audio tap" / level meter flat** — permission missing. System
Settings → Privacy & Security → Screen & System Audio Recording → *System Audio Recording Only*
→ Ensemble. Then Stop/Start broadcasting (or relaunch).

**The host's own audio is muted after the app crashed** — the tap is destroyed when the process
exits, so relaunch Ensemble (or wait a second); audio returns.

**No hosts appear on the receiver** — both Macs must be on the same network (guest Wi‑Fi
networks usually isolate clients). Check the Local Network permission on both Macs, and the
host's firewall prompt. Fall back to *Manual connection* with the host's IP and the control port
shown under *Security* on the host.

**Connects but no audio ("No answer on the audio channel")** — UDP is blocked. Allow incoming
connections for Ensemble in System Settings → Network → Firewall → Options, or turn off "Block all
incoming connections".

**Receivers show underruns, "Needs" is higher than the delay, or the other Mac sounds late** —
audio is arriving in bursts. On Wi‑Fi this is almost always the receiving MacBook's power
saving (the radio dozes between beacons and the access point holds packets for 100 ms or more)
or AWDL channel hopping (AirDrop, Handoff). Ensemble keeps the radio busy with a ping every
200 ms and holds a latency‑critical activity while streaming, but you can help a lot:

* Use **Auto** delay on the host (the default) — it settles on the smallest delay the network
  can carry. Expect 150–300 ms on a normal Wi‑Fi network and 40–60 ms on Ethernet.
* If the delay itself is what bothers you (video out of lip‑sync on the host), switch *This Mac*
  to **Direct**: the host plays instantly and only the other Macs are delayed. In the same room
  that reads as an echo, so it suits separate rooms.
* On the receiving Mac, set AirDrop to *No One* (Control Center → AirDrop) while listening;
  AirDrop discovery makes the Wi‑Fi radio hop channels every second.
* Plug the receiver into power, or connect it by Ethernet / a USB‑C hub with Ethernet.
* Prefer a 5 GHz network and stay in range of the access point.

The Sync card on the receiver shows **Headroom** (delay minus what the network needs); when it
turns orange the buffer is about to run dry.

**Crackling / underruns** — raise the latency mode, or move closer to the access point. The
Diagnostics *Underruns* counter tells you whether audio is arriving late; *Packets lost* tells you
whether it is arriving at all. Bluetooth output devices on a receiver add 100–250 ms of unreported
latency: use *Fine‑tune* on that receiver to pull it earlier (negative value) until the clicks line up.

**Echo / double click** — a receiver is not aligned. Check that its *Clock* shows *synced* and its
*Playback drift* is near 0 ms. If drift is large and constant, the output device reports the wrong
latency: use *Fine‑tune*. If it oscillates, the network jitter exceeds the buffer: pick a longer
mode.

**Testing on one Mac** — launch a receiver instance before starting the host so the host's tap
excludes it (the tap's exclusion list is built when capture starts). Use `-source tone` on the host
to avoid the permission prompt. Launch flags take the form `-flag value`; a bare `-autostart`
without `YES` is swallowed as the value of the next flag by macOS's argument parser.

**Sample rate** — the stream runs at the host's *output device* rate (44.1 kHz for many wired
headphones, 48 kHz for the built‑in speakers). Receivers convert to their own device rate
automatically, and if the host's rate changes mid‑session everybody re‑syncs within a second.

**Two instances on the same Mac both use the speakers** — expected; that's for testing the
network path only.

## 8. Verified so far (2026‑09‑16, macOS 27.0, Xcode 26.3, Apple Silicon)

* Debug and Release builds compile cleanly from `xcodebuild` and open in Xcode.
* Host and receiver instances on one Mac over loopback: Bonjour advertisement, pairing code,
  TCP handshake, UDP audio flow, 100 packets/s for 30 s with 0 lost packets, 0 underruns,
  clock offset estimate within ±0.03 ms, playback drift 0.00 ms, rate correction < 5 ppm.
* System‑audio tap: created successfully on the default output (EarPods, 44.1 kHz), IO proc
  delivers 512‑frame buffers with consistent host timestamps; the local synchronized player
  holds ≈100 ms of audio at the 150 ms setting with zero resyncs. **Not yet verified on this
  machine:** non‑silent capture, because the System Audio Recording permission dialog has to be
  accepted interactively (until then the tap delivers silence, which is what the level meter
  showed).
* Two‑Mac test on a real Wi‑Fi network: not run yet — that is your first test (§3).

## 9. Limitations & next steps

* Uncompressed 16‑bit PCM (~1.5 Mbit/s per receiver at 48 kHz stereo). Opus encoding would cut
  this by 10× and is the natural next step (`PacketChunker` is the single place to add it).
* Packet loss is concealed with silence; no forward error correction or retransmission yet.
* Output‑latency compensation relies on what the output device reports; Bluetooth devices lie.
* The host cannot capture while another app holds an exclusive tap (rare).
* macOS 14.2–14.x could work with a lower deployment target, but the project targets macOS 15
  because of the local‑network privacy API behaviour and SwiftUI features used.
