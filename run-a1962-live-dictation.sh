#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
PACKETLOGGER="$ROOT_DIR/PacketLogger.app/Contents/Resources/packetlogger"
DECODER="$ROOT_DIR/Tools/a1962_decode_capture"
DECODER_SRC="$ROOT_DIR/Tools/a1962_decode_capture.c"
BUTTON_MONITOR="$ROOT_DIR/Tools/a1962_mic_button_monitor"
BUTTON_MONITOR_SRC="$ROOT_DIR/Tools/A1962MicButtonMonitor.m"
KEEPALIVE="$ROOT_DIR/Tools/a1962_hid_keepalive"
KEEPALIVE_SRC="$ROOT_DIR/Tools/A1962HIDKeepalive.m"
KEEPALIVE_INTERVAL="${A1962_KEEPALIVE_INTERVAL:-20}"
TERMINAL_TTY="$(tty)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: ./run-a1962-live-dictation.sh"
  echo "Streams A1962 mic audio into BlackHole 2ch."
  exit 0
fi

if [[ ! -x "$PACKETLOGGER" ]]; then
  echo "Missing PacketLogger: $PACKETLOGGER" >&2
  exit 1
fi

if ! system_profiler SPConfigurationProfileDataType 2>/dev/null |
  grep -Eq "com\.(apple|goatremote|siriremotevoicecontrol)\.bluetooth\.logging"; then
  echo "Bluetooth logging profile is not installed. PacketLogger will not see Siri Remote audio." >&2
  exit 1
fi

if [[ ! -f /opt/homebrew/include/opus/opus.h || ! -f /opt/homebrew/lib/libopus.dylib ]]; then
  echo "Homebrew opus is required at /opt/homebrew. Install with: brew install opus" >&2
  exit 1
fi

if [[ ! -x "$DECODER" || "$DECODER_SRC" -nt "$DECODER" ]]; then
  clang -I /opt/homebrew/include "$DECODER_SRC" -L /opt/homebrew/lib -lopus -o "$DECODER"
fi

if [[ ! -x "$BUTTON_MONITOR" || "$BUTTON_MONITOR_SRC" -nt "$BUTTON_MONITOR" ]]; then
  clang -fobjc-arc -framework Foundation -framework IOKit "$BUTTON_MONITOR_SRC" -o "$BUTTON_MONITOR"
fi

if [[ ! -x "$KEEPALIVE" || "$KEEPALIVE_SRC" -nt "$KEEPALIVE" ]]; then
  clang -fobjc-arc -framework Foundation -framework AppKit -framework IOKit "$KEEPALIVE_SRC" -o "$KEEPALIVE"
fi

device_index="$(
  ffmpeg -hide_banner -f lavfi -i anullsrc=r=16000:cl=mono -t 0.01 -f audiotoolbox -list_devices true - 2>&1 |
    awk '/BlackHole 2ch/ { for (i=1;i<=NF;i++) if ($i ~ /^\[[0-9]+\]$/) { gsub(/\[|\]/,"",$i); print $i; exit } }'
)"

if [[ -z "$device_index" ]]; then
  echo "Could not find BlackHole 2ch as a CoreAudio output device." >&2
  exit 1
fi

echo "Starting A1962 live dictation bridge."
echo "CoreAudio output: BlackHole 2ch, index $device_index"
echo "Remote keepalive: every ${KEEPALIVE_INTERVAL}s, plus Mac wake"
echo "Set Dictation/Input to BlackHole 2ch. Press Ctrl-C to stop."
echo

# Authenticate before the terminal key listener starts so it cannot consume
# password input intended for sudo.
sudo -v
echo "Authentication successful."

bridge_events() {
  zmodload zsh/datetime
  local button_state="IDLE"
  local audio_active=0
  local last_bar="........................"
  local last_level=0
  local press_timestamp=""
  local press_to_audio_ms="----"
  local press_to_audio_total=0.0
  local press_to_audio_count=0
  local average_press_to_audio_ms="----"
  local release_timestamp=""
  local last_audio_packet_timestamp=""
  local last_voiced_packet_timestamp=""
  local release_tail_ms="----"
  local release_tail_total=0.0
  local release_tail_count=0
  local average_release_tail_ms="----"
  local voiced_tail_ms="----"
  local voiced_tail_total=0.0
  local voiced_tail_count=0
  local average_voiced_tail_ms="----"
  local autoplay_enabled=0
  local playback_pid=""
  local playback_meter_pid=""
  local playback_id=0
  local playback_active=0
  local playback_level=0
  local playback_elapsed_ms=0
  local playback_duration_ms=0
  local playback_line_visible=0

  playback_watch() {
    local watched_pid="$1"
    local watched_id="$2"
    local started_at="$EPOCHREALTIME"

    while kill -0 "$watched_pid" 2>/dev/null; do
      local elapsed_ms=$(( (EPOCHREALTIME - started_at) * 1000.0 ))
      print -r -- "EVENT playback_progress ${watched_id} ${elapsed_ms} ${playback_duration_ms}" > "$EVENT_PIPE"
      sleep 0.05
    done
    print -r -- "EVENT playback_finished ${watched_id}" > "$EVENT_PIPE"
  }

  playback_meter_watch() {
    local watched_id="$1"
    local level=""
    "$DECODER" --wav-meter "$CAPTURE_WAV" | while IFS= read -r level; do
      print -r -- "EVENT playback_meter ${watched_id} ${level}" > "$EVENT_PIPE"
    done
  }

  stop_playback() {
    if [[ -n "$playback_pid" ]] && kill -0 "$playback_pid" 2>/dev/null; then
      kill "$playback_pid" 2>/dev/null || true
    fi
    if [[ -n "$playback_meter_pid" ]] && kill -0 "$playback_meter_pid" 2>/dev/null; then
      kill "$playback_meter_pid" 2>/dev/null || true
    fi
    playback_pid=""
    playback_meter_pid=""
    playback_active=0
    playback_level=0
    (( ++playback_id ))
  }

  render_status() {
    local bar="$last_bar"
    local green=$'\033[38;5;48m'
    local yellow=$'\033[38;5;220m'
    local dim=$'\033[38;5;245m'
    local reset=$'\033[0m'
    if (( ! audio_active )); then
      bar="${dim}..........IDLE..........${reset}"
    else
      local width=24
      local filled=$(( last_level * width / 100 ))
      local green_count=$filled
      if (( green_count > 19 )); then
        green_count=19
      fi
      local active="||||||||||||||||||||||||"
      local inactive="........................"
      bar="${green}${active[1,$green_count]}${yellow}${active[$(( green_count + 1 )),$filled]}${dim}${inactive[$(( filled + 1 )),-1]}${reset}"
    fi
    local button_shape="▄▄"
    case "$button_state" in
      PRESSED)
        button_shape="▂▂"
        ;;
      RELEASED)
        button_shape="▄▄"
        ;;
    esac
    local autoplay_indicator=""
    if (( autoplay_enabled )); then
      autoplay_indicator=" ▶"
    fi
    printf '\033[?25l\r\033[2K[%s] %02d%% | %s%s | ⇡%s ⇣%s ∿%sms | μ⇡%s ⇣%s ∿%sms' \
      "$bar" "$last_level" "$button_shape" "$autoplay_indicator" \
      "$press_to_audio_ms" "$release_tail_ms" "$voiced_tail_ms" \
      "$average_press_to_audio_ms" "$average_release_tail_ms" "$average_voiced_tail_ms" > "$TERMINAL_TTY"

    if (( autoplay_enabled && playback_duration_ms > 0 )); then
      local width=24
      local elapsed_ms=$playback_elapsed_ms
      if (( elapsed_ms > playback_duration_ms )); then
        elapsed_ms=$playback_duration_ms
      fi
      local filled=0
      if (( playback_duration_ms > 0 )); then
        filled=$(( elapsed_ms * width / playback_duration_ms ))
      fi
      local active="========================"
      local inactive="........................"
      local playback_icon="■"
      local scrubber="${dim}${active}${reset}"
      if (( playback_active )); then
        playback_icon="▶"
        scrubber="${green}${active[1,$filled]}${dim}${inactive[$(( filled + 1 )),-1]}${reset}"
      fi
      local total_tenths=$(( (playback_duration_ms + 50) / 100 ))
      local total_duration=""
      printf -v total_duration '%02d:%02d.%d' \
        $(( total_tenths / 600 )) \
        $(( (total_tenths / 10) % 60 )) \
        $(( total_tenths % 10 ))
      local playback_filled=$(( playback_level * width / 100 ))
      local playback_green_count=$playback_filled
      if (( playback_green_count > 19 )); then
        playback_green_count=19
      fi
      local playback_bar="${dim}........................${reset}"
      if (( playback_active )); then
        local meter_active="||||||||||||||||||||||||"
        local meter_inactive="........................"
        playback_bar="${green}${meter_active[1,$playback_green_count]}${yellow}${meter_active[$(( playback_green_count + 1 )),$playback_filled]}${dim}${meter_inactive[$(( playback_filled + 1 )),-1]}${reset}"
      fi
      printf '\n\033[2K[%s] %s %s\n\033[2K[%s] %02d%%\033[2A\r' \
        "$scrubber" "$total_duration" "$playback_icon" "$playback_bar" "$playback_level" > "$TERMINAL_TTY"
      playback_line_visible=1
    elif (( playback_line_visible )); then
      printf '\n\033[2K\n\033[2K\033[2A\r' > "$TERMINAL_TTY"
      playback_line_visible=0
    fi
  }

  while IFS= read -r event; do
    case "$event" in
      METER\ *)
        local level="${event#METER }"
        local width=24
        local filled=$(( level * width / 100 ))
        local active="||||||||||||||||||||||||"
        local inactive="........................"
        local bar="${active[1,$filled]}${inactive[$(( filled + 1 )),-1]}"
        last_bar="$bar"
        last_level="$level"
        render_status
        ;;
      'EVENT button_pressed')
        stop_playback
        playback_elapsed_ms=0
        playback_duration_ms=0
        button_state="PRESSED"
        press_timestamp="$EPOCHREALTIME"
        press_to_audio_ms="----"
        release_timestamp=""
        last_audio_packet_timestamp=""
        last_voiced_packet_timestamp=""
        release_tail_ms="----"
        voiced_tail_ms="----"
        print -r -- "$event" >> /tmp/a1962_decoder.log
        render_status
        ;;
      'EVENT audio_started')
        audio_active=1
        last_audio_packet_timestamp=""
        last_voiced_packet_timestamp=""
        print -r -- "$event" >> /tmp/a1962_decoder.log
        render_status
        ;;
      'EVENT audio_received')
        if [[ -n "$press_timestamp" && "$press_to_audio_ms" == "----" ]]; then
          local elapsed_ms=$(( (EPOCHREALTIME - press_timestamp) * 1000.0 ))
          printf -v press_to_audio_ms '%04.0f' "$elapsed_ms"
          press_to_audio_total=$(( press_to_audio_total + elapsed_ms ))
          (( ++press_to_audio_count ))
          printf -v average_press_to_audio_ms '%04.0f' "$(( press_to_audio_total / press_to_audio_count ))"
          render_status
        fi
        print -r -- "$event" >> /tmp/a1962_decoder.log
        ;;
      'EVENT audio_packet')
        last_audio_packet_timestamp="$EPOCHREALTIME"
        ;;
      'EVENT audio_voiced_packet')
        last_voiced_packet_timestamp="$EPOCHREALTIME"
        ;;
      'EVENT button_released')
        button_state="RELEASED"
        release_timestamp="$EPOCHREALTIME"
        release_tail_ms="----"
        print -r -- "$event" >> /tmp/a1962_decoder.log
        render_status
        ;;
      'EVENT audio_ended')
        audio_active=0
        last_level=0
        if [[ -n "$release_timestamp" ]]; then
          local audio_end_timestamp="${last_audio_packet_timestamp:-$EPOCHREALTIME}"
          local elapsed_ms=$(( (audio_end_timestamp - release_timestamp) * 1000.0 ))
          if (( elapsed_ms < 0 )); then
            elapsed_ms=0
          fi
          printf -v release_tail_ms '%04.0f' "$elapsed_ms"
          release_tail_total=$(( release_tail_total + elapsed_ms ))
          (( ++release_tail_count ))
          printf -v average_release_tail_ms '%04.0f' "$(( release_tail_total / release_tail_count ))"
        fi
        if [[ -n "$release_timestamp" && -n "$last_voiced_packet_timestamp" ]]; then
          local voiced_elapsed_ms=$(( (last_voiced_packet_timestamp - release_timestamp) * 1000.0 ))
          if (( voiced_elapsed_ms < 0 )); then
            voiced_elapsed_ms=0
          fi
          printf -v voiced_tail_ms '%04.0f' "$voiced_elapsed_ms"
          voiced_tail_total=$(( voiced_tail_total + voiced_elapsed_ms ))
          (( ++voiced_tail_count ))
          printf -v average_voiced_tail_ms '%04.0f' "$(( voiced_tail_total / voiced_tail_count ))"
        fi
        print -r -- "$event" >> /tmp/a1962_decoder.log
        render_status
        if (( autoplay_enabled )) && [[ -s "$CAPTURE_WAV" ]]; then
          local capture_bytes=$(stat -f %z "$CAPTURE_WAV")
          playback_duration_ms=$(( (capture_bytes - 44) * 1000 / 32000 ))
          playback_elapsed_ms=0
          playback_active=1
          playback_level=0
          (( ++playback_id ))
          afplay "$CAPTURE_WAV" >/dev/null 2>&1 &
          playback_pid=$!
          playback_watch "$playback_pid" "$playback_id" &
          playback_meter_watch "$playback_id" &
          playback_meter_pid=$!
          render_status
        fi
        ;;
      'EVENT playback_toggled')
        if (( autoplay_enabled )); then
          autoplay_enabled=0
          stop_playback
        else
          autoplay_enabled=1
        fi
        print -r -- "$event" >> /tmp/a1962_decoder.log
        render_status
        ;;
      'EVENT playback_progress '* )
        local progress_id="" progress_elapsed_ms=0 progress_duration_ms=0
        read -r progress_id progress_elapsed_ms progress_duration_ms <<< "${event#EVENT playback_progress }"
        if (( progress_id == playback_id )); then
          playback_elapsed_ms=$progress_elapsed_ms
          playback_duration_ms=$progress_duration_ms
          render_status
        fi
        ;;
      'EVENT playback_finished '* )
        local finished_id="${event#EVENT playback_finished }"
        if (( finished_id == playback_id )); then
          playback_elapsed_ms=$playback_duration_ms
          playback_active=0
          playback_level=0
          playback_pid=""
          render_status
        fi
        ;;
      'EVENT playback_meter '* )
        local meter_id="" meter_level=0
        read -r meter_id meter_level <<< "${event#EVENT playback_meter }"
        if (( meter_id == playback_id && playback_active )); then
          playback_level=$meter_level
          render_status
        fi
        ;;
      *)
        print -r -- "$event" >> /tmp/a1962_decoder.log
        ;;
    esac
  done
}

EVENT_PIPE="/tmp/a1962_bridge_events.$$"
CAPTURE_WAV="/tmp/a1962_last_voice.wav"
mkfifo "$EVENT_PIPE"
bridge_events < "$EVENT_PIPE" &
BRIDGE_EVENTS_PID=$!
bridge_keys() {
  local key
  while IFS= read -rsk1 key < "$TERMINAL_TTY"; do
    case "$key" in
      p|P) print -r -- 'EVENT playback_toggled' > "$EVENT_PIPE" ;;
    esac
  done
}
bridge_keys &
BRIDGE_KEYS_PID=$!
"$BUTTON_MONITOR" > "$EVENT_PIPE" 2>>/tmp/a1962_button_monitor.log &
BUTTON_MONITOR_PID=$!
"$KEEPALIVE" --interval "$KEEPALIVE_INTERVAL" >>/tmp/a1962_hid_keepalive.log 2>&1 &
KEEPALIVE_PID=$!

cleanup() {
  kill "$BUTTON_MONITOR_PID" "$KEEPALIVE_PID" "$BRIDGE_EVENTS_PID" "$BRIDGE_KEYS_PID" 2>/dev/null || true
  printf '\033[?25h\n' > "$TERMINAL_TTY" 2>/dev/null || true
  rm -f "$EVENT_PIPE"
}
trap cleanup EXIT INT TERM

sudo -n /opt/homebrew/bin/gstdbuf -o0 "$PACKETLOGGER" convert -s -f nhdr |
  A1962_CAPTURE_WAV="$CAPTURE_WAV" "$DECODER" - - 2> "$EVENT_PIPE" |
  ffmpeg -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \
    -f s16le -ar 16000 -ac 1 -i - \
    -af 'aresample=48000,pan=stereo|c0=c0|c1=c0' -ar 48000 -ac 2 \
    -flush_packets 1 -f audiotoolbox -audio_device_index "$device_index" -
