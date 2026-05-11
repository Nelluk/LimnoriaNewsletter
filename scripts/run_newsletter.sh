#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [--date YYYY-MM-DD] [--force] [--dry-run] [--no-upload]
USAGE
}

emit_json() {
  local status="$1"
  local date="$2"
  local url="$3"
  local markdown="$4"
  local message="$5"

  payload="$(python3 - "$status" "$date" "$url" "$markdown" "$message" <<'PY'
import json
import sys
status, date, url, markdown, message = sys.argv[1:6]
print(json.dumps({
    "status": status,
    "date": date,
    "url": url,
    "markdown": markdown,
    "message": message,
}))
PY
)"
  printf '%s\n' "$payload"
  if [[ -n "${RUN_JSON_FILE:-}" ]]; then
    printf '%s\n' "$payload" > "$RUN_JSON_FILE" 2>/dev/null || true
  fi
}

normalize_url() {
  local url="$1"
  if [[ "$url" =~ ^https?://paste\.rs/[^[:space:]]+$ ]] && [[ ! "$url" =~ \.md$ ]]; then
    printf '%s.md\n' "$url"
  else
    printf '%s\n' "$url"
  fi
}

resolve_yesterday() {
  local tz="$1"
  if date -v-1d +%F >/dev/null 2>&1; then
    TZ="$tz" date -v-1d +%F
  else
    TZ="$tz" date -d 'yesterday' +%F
  fi
}

find_log_file() {
  local root="$1"
  local channel="$2"
  local date="$3"

  local candidate1="$root/${channel}.${date}.log"
  local candidate2="$root/${date}.log"
  local candidate3="$root/${date}_LiberaZNC.txt"

  if [[ -f "$candidate1" ]]; then
    echo "$candidate1"
    return 0
  fi
  if [[ -f "$candidate2" ]]; then
    echo "$candidate2"
    return 0
  fi
  if [[ -f "$candidate3" ]]; then
    echo "$candidate3"
    return 0
  fi
  return 1
}

extract_urls() {
  local text="$1"
  python3 - "$text" <<'PY'
import re
import sys

text = sys.argv[1]
for url in re.findall(r'https?://[^\s)]+', text):
    print(url)
PY
}

url_is_dead() {
  local url="$1"
  local http_code=""

  http_code="$(curl -sS -L -o /dev/null -w '%{http_code}' \
    --connect-timeout "$URL_CHECK_CONNECT_TIMEOUT" \
    --max-time "$URL_CHECK_TIMEOUT" \
    "$url" || true)"

  [[ "$http_code" == "404" || "$http_code" == "410" ]]
}

cached_url_has_live_target() {
  local cached="$1"
  local found=0
  local url=""

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    found=1
    # Only republish when all cached URLs are explicitly dead (404/410).
    # Treat transport issues/timeouts as unknown and keep cached URL.
    if ! url_is_dead "$url"; then
      return 0
    fi
  done < <(extract_urls "$cached")

  [[ "$found" -eq 1 ]] || return 1
  return 1
}

upload_paste_rs() {
  local file="$1"
  local attempt=1
  local url=""

  while [[ "$attempt" -le "$PASTE_UPLOAD_RETRIES" ]]; do
    if url="$(curl -fsSL \
      --connect-timeout "$PASTE_CONNECT_TIMEOUT" \
      --max-time "$PASTE_UPLOAD_TIMEOUT" \
      --data-binary @"$file" \
      "$PASTE_RS_ENDPOINT")"; then
      url="$(printf '%s' "$url" | tr -d '\r\n')"
      if [[ -n "$url" ]]; then
        normalize_url "$url"
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done

  return 1
}

upload_dpaste_preview() {
  local file="$1"
  local attempt=1
  local url=""
  local response_file=""
  local http_code=""

  while [[ "$attempt" -le "$PASTE_UPLOAD_RETRIES" ]]; do
    response_file="$(mktemp "$TMP_WORKDIR/dpaste_response.XXXXXX")"
    http_code="$(curl -sS \
      -A "newsletter-automation/1.0" \
      --connect-timeout "$PASTE_CONNECT_TIMEOUT" \
      --max-time "$PASTE_UPLOAD_TIMEOUT" \
      -o "$response_file" \
      -w '%{http_code}' \
      -F "syntax=${DPASTE_SYNTAX}" \
      -F "content=<${file}" \
      "$DPASTE_ENDPOINT" || true)"

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
      url="$(tr -d '\r\n' < "$response_file")"
      rm -f "$response_file"
      if [[ "$url" =~ ^https?:// ]]; then
        if [[ "$url" != *"${DPASTE_PREVIEW_SUFFIX}" ]]; then
          url="${url}${DPASTE_PREVIEW_SUFFIX}"
        fi
        printf '%s\n' "$url"
        return 0
      fi
    fi

    rm -f "$response_file"
    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done

  return 1
}

republish_existing_markdown() {
  local md_file="$1"
  local paste_rs_url=""
  local dpaste_url=""

  [[ -f "$md_file" ]] || return 1

  if [[ -n "$PASTE_RS_ENDPOINT" ]]; then
    paste_rs_url="$(upload_paste_rs "$md_file" || true)"
  fi

  if [[ -n "$DPASTE_ENDPOINT" ]]; then
    dpaste_url="$(upload_dpaste_preview "$md_file" || true)"
  fi

  if [[ -n "$paste_rs_url" && -n "$dpaste_url" ]]; then
    printf '%s\n' "${paste_rs_url} (${dpaste_url})"
    return 0
  fi
  if [[ -n "$paste_rs_url" ]]; then
    printf '%s\n' "$paste_rs_url"
    return 0
  fi
  if [[ -n "$dpaste_url" ]]; then
    printf '%s\n' "$dpaste_url"
    return 0
  fi

  return 1
}

TARGET_DATE=""
FORCE=0
DRY_RUN=0
NO_UPLOAD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      TARGET_DATE="${2:-}"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --no-upload)
      NO_UPLOAD=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${NEWSLETTER_ENV:-$PROJECT_ROOT/config/newsletter.env}"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${NEWSLETTER_TZ:=UTC}"
: "${NEWSLETTER_CHANNEL:=##debate2016}"
: "${CHANNEL_LOG_DIR:=}"
: "${OUTPUT_DIR:=$PROJECT_ROOT/data/output}"
: "${STATE_DIR:=$PROJECT_ROOT/data/state}"
: "${NEWSLETTER_RUNTIME_DIR:=$PROJECT_ROOT/data}"
: "${NEWSLETTER_LOG_DIR:=${NEWSLETTER_RUNTIME_DIR}/logs}"
: "${NEWSLETTER_TMP_DIR:=${NEWSLETTER_RUNTIME_DIR}/tmp}"
: "${INSTRUCTIONS_FILE:=$PROJECT_ROOT/newsletter_instructions.md}"
: "${GENERATE_SCRIPT:=$PROJECT_ROOT/scripts/generate_with_codex.sh}"
: "${PASTE_RS_ENDPOINT:=https://paste.rs}"
: "${DPASTE_ENDPOINT:=https://dpaste.com/api/v2/}"
: "${PASTE_UPLOAD_TIMEOUT:=20}"
: "${PASTE_CONNECT_TIMEOUT:=5}"
: "${PASTE_UPLOAD_RETRIES:=3}"
: "${DPASTE_SYNTAX:=md}"
: "${DPASTE_PREVIEW_SUFFIX:=-preview}"
: "${URL_CHECK_CONNECT_TIMEOUT:=4}"
: "${URL_CHECK_TIMEOUT:=8}"

if [[ -z "$CHANNEL_LOG_DIR" ]]; then
  emit_json "error" "" "" "" "CHANNEL_LOG_DIR is not configured"
  exit 1
fi

if [[ -z "$TARGET_DATE" ]]; then
  TARGET_DATE="$(resolve_yesterday "$NEWSLETTER_TZ")"
fi

if [[ ! "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  emit_json "error" "$TARGET_DATE" "" "" "Invalid date format. Use YYYY-MM-DD"
  exit 2
fi

is_dir_writable() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || return 1
  local probe="$dir/.write_probe.$$"
  if touch "$probe" >/dev/null 2>&1; then
    rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

# In some service mount namespaces, the configured output/state paths may be
# read-only. Fall back automatically for runtime files.
if ! is_dir_writable "$OUTPUT_DIR" || ! is_dir_writable "$STATE_DIR"; then
  OUTPUT_DIR="${NEWSLETTER_RUNTIME_DIR}/output"
  STATE_DIR="${NEWSLETTER_RUNTIME_DIR}/state"
fi

mkdir -p "$OUTPUT_DIR" "$STATE_DIR"
mkdir -p "$NEWSLETTER_LOG_DIR" 2>/dev/null || true
mkdir -p "$NEWSLETTER_TMP_DIR" 2>/dev/null || true

MD_FILE="$OUTPUT_DIR/newsletter-${TARGET_DATE}.md"
URL_FILE="$OUTPUT_DIR/newsletter-${TARGET_DATE}.url"
if [[ "$DRY_RUN" -eq 1 ]]; then
  MD_FILE="$OUTPUT_DIR/dry_run_newsletter.md"
fi
LOCK_FILE="${NEWSLETTER_LOCK_FILE:-$STATE_DIR/.newsletter.lock}"
LOCK_META_FILE="${LOCK_FILE}.meta"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_JSON_FILE="${NEWSLETTER_LOG_DIR}/newsletter-${TARGET_DATE}.${RUN_ID}.json"
RUN_STDERR_FILE="${NEWSLETTER_LOG_DIR}/newsletter-${TARGET_DATE}.${RUN_ID}.stderr.log"

# Use kernel file locking to avoid stale lock directories/PID reuse issues.
TMP_WORKDIR="$(mktemp -d -p "$NEWSLETTER_TMP_DIR" newsletter-runtime.XXXXXX 2>/dev/null || mktemp -d)"
cleanup_runtime() {
  rm -f "$LOCK_META_FILE" 2>/dev/null || true
  rm -rf "$TMP_WORKDIR" 2>/dev/null || true
}
trap cleanup_runtime EXIT

# Some service contexts can execute the script but expose STATE_DIR as read-only.
# Fall back to /tmp lock files in that case.
if ! exec {LOCK_FD}> "$LOCK_FILE" 2>/dev/null; then
  LOCK_FILE="/tmp/newsletter_automation.lock"
  LOCK_META_FILE="/tmp/newsletter_automation.lock.meta"
  if ! exec {LOCK_FD}> "$LOCK_FILE" 2>/dev/null; then
    emit_json "error" "$TARGET_DATE" "" "$MD_FILE" "Could not open lock file"
    exit 1
  fi
fi

if ! flock -n "$LOCK_FD"; then
  holder="$(tr -d '\n' < "$LOCK_META_FILE" 2>/dev/null || true)"
  if [[ -n "$holder" ]]; then
    emit_json "busy" "$TARGET_DATE" "" "$MD_FILE" "Another newsletter job is running ($holder)"
  else
    emit_json "busy" "$TARGET_DATE" "" "$MD_FILE" "Another newsletter job is running"
  fi
  # Exit success so older plugin code paths still parse/report the JSON payload.
  exit 0
fi
printf 'pid=%s started=%s host=%s\n' "$$" "$(date -u +%FT%TZ)" "$(hostname -s 2>/dev/null || hostname)" > "$LOCK_META_FILE"

gen_err_file="$RUN_STDERR_FILE"
if ! : > "$gen_err_file" 2>/dev/null; then
  gen_err_file=""
fi

if [[ -n "$gen_err_file" ]]; then
  {
    printf 'started=%s\n' "$(date -u +%FT%TZ)"
    printf 'date=%s\n' "$TARGET_DATE"
    printf 'dry_run=%s force=%s\n' "$DRY_RUN" "$FORCE"
    printf 'output_file=%s\n' "$MD_FILE"
  } >> "$gen_err_file"
fi

if [[ "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 && -f "$URL_FILE" ]]; then
  cached_url="$(tr -d '\n' < "$URL_FILE")"
  cached_url="$(normalize_url "$cached_url")"
  printf '%s\n' "$cached_url" > "$URL_FILE"

  if cached_url_has_live_target "$cached_url"; then
    emit_json "cached" "$TARGET_DATE" "$cached_url" "$MD_FILE" "Using cached URL"
    exit 0
  fi

  if [[ -f "$MD_FILE" ]]; then
    if refreshed_url="$(republish_existing_markdown "$MD_FILE")"; then
      refreshed_url="$(normalize_url "$refreshed_url")"
      printf '%s\n' "$refreshed_url" > "$URL_FILE"
      emit_json "generated" "$TARGET_DATE" "$refreshed_url" "$MD_FILE" "Reposted cached markdown"
      exit 0
    fi
  fi
fi

if ! LOG_FILE="$(find_log_file "$CHANNEL_LOG_DIR" "$NEWSLETTER_CHANNEL" "$TARGET_DATE")"; then
  emit_json "error" "$TARGET_DATE" "" "$MD_FILE" "Log file not found in CHANNEL_LOG_DIR"
  exit 1
fi

cmd=(
  "$GENERATE_SCRIPT"
  --date "$TARGET_DATE"
  --log-file "$LOG_FILE"
  --output "$MD_FILE"
  --instructions "$INSTRUCTIONS_FILE"
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  cmd+=(--dry-run)
fi

if [[ "$NO_UPLOAD" -eq 1 ]]; then
  cmd+=(--no-upload)
fi

if [[ -n "$gen_err_file" ]]; then
  printf 'log_file=%s\n' "$LOG_FILE" >> "$gen_err_file"
  if ! generated_url="$("${cmd[@]}" 2>>"$gen_err_file")"; then
    gen_detail="$(tail -n 1 "$gen_err_file" 2>/dev/null | tr -d '\r' || true)"
    if grep -qiE 'codex auth unavailable|reauthenticate|refresh_token_reused|failed to refresh token|log out and sign in again' <<<"$gen_detail"; then
      emit_json "error" "$TARGET_DATE" "" "$MD_FILE" "Codex auth unavailable. Bot owner needs to reauthenticate."
    elif [[ -n "$gen_detail" ]]; then
      emit_json "error" "$TARGET_DATE" "" "$MD_FILE" "Generation failed: $gen_detail"
    else
      emit_json "error" "$TARGET_DATE" "" "$MD_FILE" "Generation failed"
    fi
    exit 1
  fi
else
  if ! generated_url="$("${cmd[@]}")"; then
    emit_json "error" "$TARGET_DATE" "" "$MD_FILE" "Generation failed"
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  generated_url="$(normalize_url "$generated_url")"
  if [[ -n "$generated_url" ]]; then
    printf '%s\n' "$generated_url" > "$URL_FILE"
    emit_json "generated" "$TARGET_DATE" "$generated_url" "$MD_FILE" "Generated and posted"
  else
    emit_json "generated" "$TARGET_DATE" "" "$MD_FILE" "Generated markdown without upload"
  fi
else
  generated_url="$(normalize_url "$generated_url")"
  if [[ -n "$generated_url" ]]; then
    emit_json "dry-run" "$TARGET_DATE" "$generated_url" "$MD_FILE" "Generated dry-run markdown and posted"
  else
    emit_json "dry-run" "$TARGET_DATE" "" "$MD_FILE" "Generated dry-run markdown without upload"
  fi
fi
