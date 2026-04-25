#!/usr/bin/env bash
set -euo pipefail

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
      wtype "${text}"
      ;;
    type_enter)
      command -v wtype >/dev/null 2>&1 || {
        echo "wtype is required for VOICE_OUTPUT_MODE=type_enter" >&2
        return 1
      }
      wtype "${text}"
      wtype -k Return
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
      printf '%s' "${text}" | wl-copy
      wtype -M ctrl -k v -m ctrl
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

  curl_args=(
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

  show_status "uconsole voice" "识别中..." "65" "0"
  if ! run_whisper_curl "${curl_args[@]}" >"${response_file}"; then
    show_status "uconsole voice" "Whisper 请求失败" "0" "1200"
    rm -f "${response_file}"
    [[ "${VOICE_KEEP_AUDIO}" == "1" ]] || rm -f "${AUDIO_FILE}"
    exit 1
  fi

  local text
  text=$(jq -r "${WHISPER_TEXT_JQ}" "${response_file}" | trim)
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
WHISPER_URL=${WHISPER_URL:-}
WHISPER_MODEL=${WHISPER_MODEL:-}
WHISPER_LANGUAGE=${WHISPER_LANGUAGE:-}
WHISPER_AUTH_TOKEN=${WHISPER_AUTH_TOKEN:-}
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
