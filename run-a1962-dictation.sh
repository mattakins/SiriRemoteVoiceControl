#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
PACKETLOGGER="$ROOT_DIR/PacketLogger.app/Contents/Resources/packetlogger"
SRVC="$ROOT_DIR/Release/SiriRemoteVoiceControl/SiriRemoteVoiceControl"
REMOTE_FILTER="${1:-${A1962_REMOTE_FILTER:-}}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: ./run-a1962-dictation.sh [remote-name-or-mac]"
  echo
  echo "Set A1962_REMOTE_FILTER instead of passing the filter as an argument."
  echo "Use this after installing the Bluetooth logging profile."
  exit 0
fi

if [[ -z "$REMOTE_FILTER" ]]; then
  echo "A remote name or Bluetooth address is required." >&2
  echo "Usage: ./run-a1962-dictation.sh <remote-name-or-mac>" >&2
  exit 2
fi

if [[ ! -x "$PACKETLOGGER" ]]; then
  echo "Missing PacketLogger: $PACKETLOGGER" >&2
  exit 1
fi

if [[ ! -x "$SRVC" ]]; then
  echo "Missing SiriRemoteVoiceControl binary: $SRVC" >&2
  exit 1
fi

if ! system_profiler SPConfigurationProfileDataType 2>/dev/null |
  grep -Eq "com\.(apple|goatremote|siriremotevoicecontrol)\.bluetooth\.logging"; then
  echo "Bluetooth logging profile is not installed. PacketLogger will not see Siri Remote audio." >&2
  exit 1
fi

if ! system_profiler SPAudioDataType 2>/dev/null | grep -q "Soundflower (2ch)"; then
  echo "Soundflower (2ch) audio device is missing. SRVC outputs decoded mic audio there." >&2
  exit 1
fi

echo "Starting A1962 dictation bridge."
echo "Remote filter: $REMOTE_FILTER"
echo "Set Dictation/Input to Soundflower (2ch), then hold the remote mic button."
echo "Press Ctrl-C to stop."
echo

sudo "$PACKETLOGGER" convert -s -f nhdr | "$SRVC" "$REMOTE_FILTER"
