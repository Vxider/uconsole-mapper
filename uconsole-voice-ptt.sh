#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

IME_WAS_ACTIVE=0

usage() {
  cat <<'EOF'
Usage:
  uconsole-voice-ptt start
  uconsole-voice-ptt stop

Configuration is read from:
  $VOICE_PTT_CONFIG
  ~/.config/uconsole-mapper/voice.env

Supported variables:
  WHISPER_URL            required, whisper endpoint
  WHISPER_MODEL          optional multipart field
  WHISPER_LANGUAGE       optional multipart field
  WHISPER_AUTH_TOKEN     optional bearer token
  WHISPER_PROMPT         optional short ASR prompt hint
  WHISPER_PROMPT_FIELD   multipart field for ASR prompt, default: prompt
  WHISPER_CONTEXT_FIELD  multipart field for tmux context, default: contextText
  WHISPER_ENABLE_CORRECTION
                         1 sends enableCorrection=true, default: 1
  WHISPER_TEXT_JQ        jq expression, default: .text // .result.text // .data.text // empty
  WHISPER_NO_PROXY       1 disables proxy for whisper requests, default: 1
  VOICE_OUTPUT_MODE      type | type_enter | clipboard | paste, default: type
  VOICE_RECORDER         auto | pw-record | ffmpeg | arecord, default: auto
  VOICE_INPUT            default audio input name, used by ffmpeg, default: default
  VOICE_MIN_RECORD_MS    minimum press duration before transcription, default: 350
  VOICE_SAMPLE_RATE      default: 16000
  VOICE_CHANNELS         default: 1
  VOICE_STATE_DIR        default: ${XDG_STATE_HOME:-~/.local/state}/uconsole-mapper
  VOICE_KEEP_AUDIO       1 keeps recorded audio after stop, default: 0
  VOICE_TMUX_CONTEXT     1 adds active tmux pane visible text as ASR context, default: 1
  VOICE_TMUX_CONTEXT_LINES
                        minimum lines sent from the active tmux pane, default: 30
  VOICE_TMUX_CONTEXT_MAX_CHARS
                        max chars sent from tmux context, default: 1200
EOF
}

show_status() {
  local summary=$1
  local body=${2:-}
  local value=${3:-}
  local timeout=${4:-1200}

  if command -v dunstify >/dev/null 2>&1; then
    local args=(-a "uconsole-voice" -r "${VOICE_NOTIFY_ID}" -u low -t "${timeout}")
    if [[ -n "${value}" ]]; then
      args+=(-h "int:value:${value}")
    fi
    dunstify "${args[@]}" "${summary}" "${body}" >/dev/null 2>&1 || true
    return
  fi

  if command -v notify-send >/dev/null 2>&1; then
    notify-send "${summary}" "${body}" >/dev/null 2>&1 || true
  fi
}

show_recording_status() {
  if command -v dunstify >/dev/null 2>&1; then
    dunstify -a "uconsole-voice" -r "${VOICE_NOTIFY_ID}" -u low -t 0 -h "int:value:20" "uconsole voice" "录音中..." >/dev/null 2>&1 || true
    return
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "uconsole voice" "录音中..." >/dev/null 2>&1 || true
  fi
}

get_fcitx5_state() {
  command -v fcitx5-remote >/dev/null 2>&1 || return 1
  local state
  state=$(fcitx5-remote 2>/dev/null || true)
  [[ "${state}" =~ ^[012]$ ]] || return 1
  printf '%s\n' "${state}"
}

suspend_ime_for_injection() {
  IME_WAS_ACTIVE=0
  local state
  state=$(get_fcitx5_state || true)
  if [[ "${state}" == "2" ]]; then
    fcitx5-remote -c >/dev/null 2>&1 || true
    IME_WAS_ACTIVE=1
  fi
}

restore_ime_after_injection() {
  if [[ "${IME_WAS_ACTIVE}" == "1" ]]; then
    fcitx5-remote -o >/dev/null 2>&1 || true
  fi
  IME_WAS_ACTIVE=0
}

with_ime_suspended() {
  local status=0
  suspend_ime_for_injection
  "$@" || status=$?
  restore_ime_after_injection
  return "${status}"
}

type_text() {
  local text=$1
  wtype "${text}"
}

type_text_and_enter() {
  local text=$1
  wtype "${text}"
  wtype -k Return
}

paste_text() {
  local text=$1
  printf '%s' "${text}" | wl-copy
  wtype -M ctrl -k v -m ctrl
}

run_whisper_curl() {
  local -a args=("$@")

  if [[ "${WHISPER_NO_PROXY}" == "1" ]]; then
    env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      -u http_proxy -u https_proxy -u all_proxy \
      curl --noproxy '*' "${args[@]}"
    return
  fi

  curl "${args[@]}"
}

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_transcript() {
  tr '\r\n' '  ' | sed 's/[[:space:]]\+/ /g' | trim
}

wait_for_exit() {
  local pid=$1
  local timeout=$2
  local elapsed=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      return 1
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  return 0
}

choose_recorder() {
  case "${VOICE_RECORDER}" in
    auto)
      if command -v pw-record >/dev/null 2>&1; then
        echo "pw-record"
        return 0
      fi
      if command -v ffmpeg >/dev/null 2>&1; then
        echo "ffmpeg"
        return 0
      fi
      if command -v arecord >/dev/null 2>&1; then
        echo "arecord"
        return 0
      fi
      ;;
    pw-record|ffmpeg|arecord)
      if command -v "${VOICE_RECORDER}" >/dev/null 2>&1; then
        echo "${VOICE_RECORDER}"
        return 0
      fi
      echo "configured recorder not found: ${VOICE_RECORDER}" >&2
      return 1
      ;;
    *)
      echo "unsupported recorder: ${VOICE_RECORDER}" >&2
      return 1
      ;;
  esac

  echo "no supported recorder found; install pw-record, ffmpeg, or arecord" >&2
  return 1
}

terminal_window_is_active() {
  local spec
  local specs=(
    "title:QuickTerm"
    "app_id:lxterminal"
    "app_id:QuickTerm"
    "app_id:quickterm"
  )

  [[ -x "${WLRCTL}" ]] || return 1

  for spec in "${specs[@]}"; do
    if "${WLRCTL}" window find "${spec}" "state:active" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

resolve_tmux_window_target() {
  local best_activity=-1
  local best_window=
  local best_session=
  local control_mode activity session_name window_id

  command -v tmux >/dev/null 2>&1 || return 1

  while IFS=$'\t' read -r control_mode activity session_name window_id; do
    [[ "${control_mode}" == "1" ]] && continue
    [[ -n "${window_id}" ]] || continue
    [[ -n "${activity}" ]] || continue

    if (( activity > best_activity )); then
      best_activity=${activity}
      best_window=${window_id}
      best_session=${session_name}
    fi
  done < <(
    tmux list-clients -F '#{?client_control_mode,1,0}'$'\t''#{client_activity}'$'\t''#{session_name}'$'\t''#{window_id}' 2>/dev/null || true
  )

  [[ -n "${best_window}" ]] || return 1
  printf '%s\t%s\n' "${best_session}" "${best_window}"
}

capture_tmux_window_context() {
  local session_name window_id
  local window_name=
  local context=
  local pane_id=
  local pane_index=
  local pane_command=
  local pane_text

  [[ "${VOICE_TMUX_CONTEXT}" == "1" ]] || return 1
  terminal_window_is_active || return 1

  IFS=$'\t' read -r session_name window_id < <(resolve_tmux_window_target) || return 1
  window_name=$(
    tmux display-message -p -t "${window_id}" '#{window_name}' 2>/dev/null | tr -d '\r' || true
  )

  context=$(printf 'tmux session: %s\n' "${session_name:-unknown}")
  context+=$(printf 'tmux window: %s\n' "${window_name:-${window_id}}")

  IFS=$'\t' read -r pane_id pane_index pane_command < <(
    tmux list-panes -t "${window_id}" -F '#{?pane_active,#{pane_id}\t#{pane_index}\t#{pane_current_command},}' 2>/dev/null \
      | awk 'NF { print; exit }'
  ) || true
  [[ -n "${pane_id}" ]] || return 1

  pane_text=$(
    tmux capture-pane -p -t "${pane_id}" 2>/dev/null | tr -d '\r' || true
  )
  local visible_line_count=0
  visible_line_count=$(printf '%s\n' "${pane_text}" | awk 'END { print NR }')
  if (( visible_line_count < VOICE_TMUX_CONTEXT_LINES )); then
    pane_text=$(
      tmux capture-pane -p -S "-${VOICE_TMUX_CONTEXT_LINES}" -t "${pane_id}" 2>/dev/null | tr -d '\r' || true
    )
  fi
  [[ -n "${pane_text}" ]] || return 1

  context+=$'\n'
  context+=$(printf '[active pane %s command=%s]\n' \
    "${pane_index:-?}" \
    "${pane_command:-unknown}")
  context+="${pane_text}"$'\n'

  [[ -n "${context}" ]] || return 1

  if (( ${#context} > VOICE_TMUX_CONTEXT_MAX_CHARS )); then
    context=${context: -$VOICE_TMUX_CONTEXT_MAX_CHARS}
  fi

  printf '%s\n' "${context}"
}

build_whisper_prompt() {
  [[ -n "${WHISPER_PROMPT}" ]] || return 1
  printf '%s\n' "${WHISPER_PROMPT}"
}

build_whisper_context() {
  local tmux_context=
  tmux_context=$(capture_tmux_window_context || true)
  [[ -n "${tmux_context}" ]] || return 1
  printf '%s\n' "${tmux_context}"
}

start_recording() {
  mkdir -p "${VOICE_STATE_DIR}"
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    if [[ -n "${RECORDER_PID:-}" ]] && kill -0 "${RECORDER_PID}" >/dev/null 2>&1; then
      exit 0
    fi
    rm -f "${STATE_FILE}"
  fi

  local recorder
  recorder=$(choose_recorder)
  local audio_file
  audio_file=$(mktemp "${VOICE_STATE_DIR}/voice-XXXXXX.wav")

  case "${recorder}" in
    pw-record)
      setsid pw-record \
        --rate "${VOICE_SAMPLE_RATE}" \
        --channels "${VOICE_CHANNELS}" \
        "${audio_file}" >/dev/null 2>&1 &
      ;;
    ffmpeg)
      setsid ffmpeg \
        -hide_banner \
        -loglevel error \
        -y \
        -f pulse \
        -i "${VOICE_INPUT}" \
        -ac "${VOICE_CHANNELS}" \
        -ar "${VOICE_SAMPLE_RATE}" \
        "${audio_file}" >/dev/null 2>&1 &
      ;;
    arecord)
      setsid arecord \
        -q \
        -f S16_LE \
        -r "${VOICE_SAMPLE_RATE}" \
        -c "${VOICE_CHANNELS}" \
        "${audio_file}" >/dev/null 2>&1 &
      ;;
  esac

  local recorder_pid=$!
  cat >"${STATE_FILE}" <<EOF
RECORDER_PID=${recorder_pid}
AUDIO_FILE=$(printf '%q' "${audio_file}")
RECORDER_NAME=${recorder}
STARTED_AT_MS=$(date +%s%3N)
EOF
  show_recording_status
}

inject_text() {
  local text=$1
  case "${VOICE_OUTPUT_MODE}" in
    type)
      command -v wtype >/dev/null 2>&1 || {
        echo "wtype is required for VOICE_OUTPUT_MODE=type" >&2
        return 1
      }
      with_ime_suspended type_text "${text}"
      ;;
    type_enter)
      command -v wtype >/dev/null 2>&1 || {
        echo "wtype is required for VOICE_OUTPUT_MODE=type_enter" >&2
        return 1
      }
      with_ime_suspended type_text_and_enter "${text}"
      ;;
    clipboard)
      command -v wl-copy >/dev/null 2>&1 || {
        echo "wl-copy is required for VOICE_OUTPUT_MODE=clipboard" >&2
        return 1
      }
      printf '%s' "${text}" | wl-copy
      ;;
    paste)
      command -v wl-copy >/dev/null 2>&1 || {
        echo "wl-copy is required for VOICE_OUTPUT_MODE=paste" >&2
        return 1
      }
      command -v wtype >/dev/null 2>&1 || {
        echo "wtype is required for VOICE_OUTPUT_MODE=paste" >&2
        return 1
      }
      with_ime_suspended paste_text "${text}"
      ;;
    *)
      echo "unsupported VOICE_OUTPUT_MODE: ${VOICE_OUTPUT_MODE}" >&2
      return 1
      ;;
  esac
}

stop_recording() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    exit 0
  fi

  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  rm -f "${STATE_FILE}"

  if [[ -z "${RECORDER_PID:-}" || -z "${AUDIO_FILE:-}" ]]; then
    echo "state file is incomplete" >&2
    exit 1
  fi

  local stopped_at_ms duration_ms
  stopped_at_ms=$(date +%s%3N)
  duration_ms=0
  if [[ -n "${STARTED_AT_MS:-}" ]]; then
    duration_ms=$((stopped_at_ms - STARTED_AT_MS))
  fi

  if kill -0 "${RECORDER_PID}" >/dev/null 2>&1; then
    kill -INT "${RECORDER_PID}" >/dev/null 2>&1 || true
    if ! wait_for_exit "${RECORDER_PID}" 30; then
      kill -TERM "${RECORDER_PID}" >/dev/null 2>&1 || true
      wait_for_exit "${RECORDER_PID}" 20 || true
    fi
  fi

  if (( duration_ms < VOICE_MIN_RECORD_MS )); then
    show_status "uconsole voice" "录音太短，已取消" "0" "800"
    [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
    exit 0
  fi

  if [[ ! -s "${AUDIO_FILE}" ]]; then
    echo "recorded audio is empty" >&2
    show_status "uconsole voice" "录音失败" "0" "1000"
    [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
    exit 1
  fi

  if [[ -z "${WHISPER_URL}" ]]; then
    echo "WHISPER_URL is required" >&2
    show_status "uconsole voice" "未配置 WHISPER_URL" "0" "1200"
    exit 1
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required" >&2
    exit 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 1
  }

  local response_file
  response_file=$(mktemp "${VOICE_STATE_DIR}/whisper-XXXXXX.json")

  local prompt_text=
  local context_text=
  local -a curl_args=(
    -fsS
    -X POST
    "${WHISPER_URL}"
    -F "file=@${AUDIO_FILE}"
  )
  if [[ -n "${WHISPER_AUTH_TOKEN}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${WHISPER_AUTH_TOKEN}")
  fi
  if [[ -n "${WHISPER_MODEL}" ]]; then
    curl_args+=(-F "model=${WHISPER_MODEL}")
  fi
  if [[ -n "${WHISPER_LANGUAGE}" ]]; then
    curl_args+=(-F "language=${WHISPER_LANGUAGE}")
  fi
  if [[ "${WHISPER_ENABLE_CORRECTION}" == "1" ]]; then
    curl_args+=(-F "enableCorrection=true")
  fi
  prompt_text=$(build_whisper_prompt || true)
  if [[ -n "${prompt_text}" ]]; then
    curl_args+=(--form-string "${WHISPER_PROMPT_FIELD}=${prompt_text}")
  fi
  context_text=$(build_whisper_context || true)
  if [[ -n "${context_text}" ]]; then
    curl_args+=(--form-string "${WHISPER_CONTEXT_FIELD}=${context_text}")
  fi

  show_status "uconsole voice" "识别中..." "65" "0"
  if ! run_whisper_curl "${curl_args[@]}" >"${response_file}"; then
    show_status "uconsole voice" "Whisper 请求失败" "0" "1200"
    rm -f "${response_file}"
    [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
    exit 1
  fi

  local text
  text=$(jq -r "${WHISPER_TEXT_JQ}" "${response_file}" | normalize_transcript)
  rm -f "${response_file}"

  if [[ -z "${text}" ]]; then
    show_status "uconsole voice" "未识别到文本" "0" "1000"
    [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
    exit 1
  fi

  if ! inject_text "${text}"; then
    show_status "uconsole voice" "文本注入失败" "0" "1200"
    [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
    exit 1
  fi

  show_status "uconsole voice" "已输入: ${text}" "90" "900"
  [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
}

ACTION=${1:-}
if [[ "${ACTION}" == "-h" || "${ACTION}" == "--help" || -z "${ACTION}" ]]; then
  usage
  exit 0
fi

CONFIG_FILE=${VOICE_PTT_CONFIG:-"${HOME}/.config/uconsole-mapper/voice.env"}
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

VOICE_STATE_DIR=${VOICE_STATE_DIR:-"${XDG_STATE_HOME:-${HOME}/.local/state}/uconsole-mapper"}
STATE_FILE="${VOICE_STATE_DIR}/voice-ptt.state"
VOICE_RECORDER=${VOICE_RECORDER:-auto}
VOICE_INPUT=${VOICE_INPUT:-default}
VOICE_MIN_RECORD_MS=${VOICE_MIN_RECORD_MS:-350}
VOICE_SAMPLE_RATE=${VOICE_SAMPLE_RATE:-16000}
VOICE_CHANNELS=${VOICE_CHANNELS:-1}
VOICE_OUTPUT_MODE=${VOICE_OUTPUT_MODE:-type}
VOICE_KEEP_AUDIO=${VOICE_KEEP_AUDIO:-0}
VOICE_NOTIFY_ID=${VOICE_NOTIFY_ID:-991199}
VOICE_TMUX_CONTEXT=${VOICE_TMUX_CONTEXT:-1}
VOICE_TMUX_CONTEXT_LINES=${VOICE_TMUX_CONTEXT_LINES:-30}
VOICE_TMUX_CONTEXT_MAX_CHARS=${VOICE_TMUX_CONTEXT_MAX_CHARS:-1200}
WLRCTL=${WLRCTL:-"${HOME}/.local/bin/wlrctl"}
WHISPER_URL=${WHISPER_URL:-}
WHISPER_MODEL=${WHISPER_MODEL:-}
WHISPER_LANGUAGE=${WHISPER_LANGUAGE:-}
WHISPER_AUTH_TOKEN=${WHISPER_AUTH_TOKEN:-}
WHISPER_PROMPT=${WHISPER_PROMPT:-}
WHISPER_PROMPT_FIELD=${WHISPER_PROMPT_FIELD:-prompt}
WHISPER_CONTEXT_FIELD=${WHISPER_CONTEXT_FIELD:-contextText}
WHISPER_ENABLE_CORRECTION=${WHISPER_ENABLE_CORRECTION:-1}
WHISPER_TEXT_JQ=${WHISPER_TEXT_JQ:-'.text // .result.text // .data.text // empty'}
WHISPER_NO_PROXY=${WHISPER_NO_PROXY:-1}

case "${ACTION}" in
  start)
    start_recording
    ;;
  stop)
    stop_recording
    ;;
  *)
    echo "unknown action: ${ACTION}" >&2
    usage >&2
    exit 2
    ;;
esac
