# SiriRemoteVoiceControl — A1962 Mic on macOS

## Goal
Use the Apple Siri Remote 1st-gen (A1962, glass touchpad, Lightning) microphone as a macOS audio input device on Apple Silicon / macOS 26.

## What Works

### The live pipeline
```bash
cd /Users/matt/Repos/SiriRemoteVoiceControl
./run-a1962-live-dictation.sh
```

- Prompts for sudo password (required for PacketLogger)
- Streams A1962 mic audio into **BlackHole 2ch** in real time
- Set macOS Dictation / any app's input to **BlackHole 2ch**
- Hold the **side mic button** on the remote to transmit; release to stop
- Multiple consecutive push-to-talks work (no restart needed)
- A read-only HID keepalive prevents the first mic press being consumed by Bluetooth reconnect
- The keepalive refreshes immediately when the Mac wakes
- Ctrl-C to stop

### Prerequisites
| Requirement | How to install |
|---|---|
| BlackHole 2ch | `brew install --cask blackhole-2ch` then `sudo killall coreaudiod` |
| Opus | `brew install opus` |
| coreutils (gstdbuf) | `brew install coreutils` |
| PacketLogger.app | Apple Developer downloads → Additional Tools for Xcode → Hardware/PacketLogger.app → copy to repo root |
| Bluetooth logging profile | Open `Profiles/Bluetooth_A1962_Logging.mobileconfig` → Install in Device Management → restart |
| A1962 paired to Mac | Hold **Menu + Volume Up** ~5s → appears in System Settings → Bluetooth → Connect |

## Architecture

```
A1962 mic (BT) → HCI bus
  → PacketLogger (sudo, sniffs HCI with BT debug profile)
  → gstdbuf -o0 (forces per-byte flush, kills ~1s buffering delay)
  → a1962_decode_capture (custom C decoder)
      - detects 0x1B 0x23 voice_start / voice_end markers
      - reassembles 31-byte HCI chunks into Opus frames
      - decodes Opus 16kHz mono → s16le PCM
      - emits 20ms silence every poll timeout to keep CoreAudio alive
  → ffmpeg (s16le 16kHz → audiotoolbox)
  → BlackHole 2ch (virtual loopback)
  → macOS Dictation / any app
```

## Key Technical Findings

**Why this is hard on Apple Silicon / macOS 26:**
- The A1962 does NOT pair to macOS as a standard BLE audio peripheral
- PacketLogger with no BT profile installed captures zero HCI data (Apple locked this down post-2020)
- The project Bluetooth logging profile re-enables HCI trace capture
- `gstdbuf -o0` is required — PacketLogger block-buffers at 4-8KB when piped, causing ~1s delay
- After first mic transmission, the CoreAudio audiotoolbox sink stalls if no audio flows. Fixed by emitting silence frames between transmissions (poll loop with 20ms timeout in decoder)

**A1962 packet format (reverse engineered):**
- Voice start marker: `0x1B 0x23 0x00 0x00 0x10` (suffix match in HCI RECV packet)
- Voice end marker: `0x1B 0x23 0x00 0x10 0x00`
- Mic data: 31-byte RECV packets, `bytes[1]==0x20`, `bytes[18]==0xB8`
- Opus codec, 16kHz mono, 20ms frames

**What does NOT work for A1962 mic on macOS 26:**
- Original SiriRemoteVoiceControl binary (x86_64, hardcodes Soundflower, pre-2020 approach)
- GoatRemote (built for 2nd/3rd gen Siri Remote audio protocol only)
- BetterTouchTool, Remote Buddy (buttons/trackpad only, no mic)
- PacketLogger CLI without BT logging profile (zero capture)

## Known Issues / Remaining Rough Edges

- **Requires sudo terminal** — PacketLogger needs root. Terminal must stay open.
- **BT logging profile causes trackpad stutter** — The mobileconfig enables global BT debug logging. On some workloads this adds perceptible latency to Magic Trackpad / Magic Keyboard. Uninstall (System Settings → General → Device Management) when not using mic; reinstall when needed.
- **No auto-start** — pipeline must be re-run after reboot. Wrapping in a LaunchDaemon would fix this.
- **Pairing** — A1962 may need to be re-paired after long sleep or disconnect from Apple TV. Hold Menu + Vol Up again.

The keepalive interval defaults to 20 seconds. Override it when launching the
bridge with `A1962_KEEPALIVE_INTERVAL=60 ./run-a1962-live-dictation.sh`.

## Files

| File | Purpose |
|---|---|
| `run-a1962-live-dictation.sh` | Main entry point |
| `Tools/a1962_decode_capture.c` | HCI parser + Opus decoder (source) |
| `Tools/a1962_decode_capture` | Compiled binary (rebuilt automatically by script when source is newer) |
| `PacketLogger.app` | From Apple Additional Tools for Xcode — not committed, copy here manually |

## Remote also works for buttons + trackpad
The A1962 pairs to macOS and its HID events (Vol Up/Down, Menu, Play/Pause, Siri button) are delivered via standard IOKit. **HyperVibe** (`/Users/matt/Repos/hypervibe`) handles these over BT with no additional drivers. The trackpad surface also works via `MultitouchSupport.framework`. Note: HyperVibe and BetterTouchTool both grab the trackpad — running both causes a connect/disconnect flap; disable one.
