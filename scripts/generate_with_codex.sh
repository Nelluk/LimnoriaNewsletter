#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --date YYYY-MM-DD --log-file /path/to/log --output /path/to/output.md --instructions /path/to/instructions.md [--dry-run] [--no-upload]
USAGE
}

DATE=""
LOG_FILE=""
OUTPUT_FILE=""
INSTRUCTIONS_FILE=""
DRY_RUN=0
NO_UPLOAD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      DATE="${2:-}"; shift 2 ;;
    --log-file)
      LOG_FILE="${2:-}"; shift 2 ;;
    --output)
      OUTPUT_FILE="${2:-}"; shift 2 ;;
    --instructions)
      INSTRUCTIONS_FILE="${2:-}"; shift 2 ;;
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

[[ -n "$DATE" && -n "$LOG_FILE" && -n "$OUTPUT_FILE" && -n "$INSTRUCTIONS_FILE" ]] || {
  usage
  exit 2
}

[[ -f "$LOG_FILE" ]] || { echo "Missing log file: $LOG_FILE" >&2; exit 1; }
[[ -f "$INSTRUCTIONS_FILE" ]] || { echo "Missing instructions file: $INSTRUCTIONS_FILE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${NEWSLETTER_ENV:-$PROJECT_ROOT/config/newsletter.env}"
ENV_FILE_LOADED=0
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  ENV_FILE_LOADED=1
fi

: "${CODEX_BIN:=codex}"
: "${CODEX_WORKDIR:=$PROJECT_ROOT}"
: "${NEWSLETTER_CHANNEL:=##debate2016}"
: "${PASTERS_IO_ENDPOINT:=https://pasters.io/}"
: "${PASTE_RS_ENDPOINT:=${PASTE_ENDPOINT:-https://paste.rs}}"
: "${DPASTE_ENDPOINT:=https://dpaste.com/api/v2/}"
: "${PASTE_UPLOAD_TIMEOUT:=20}"
: "${PASTE_CONNECT_TIMEOUT:=5}"
: "${PASTE_UPLOAD_RETRIES:=3}"
: "${DPASTE_SYNTAX:=md}"
: "${DPASTE_PREVIEW_SUFFIX:=-preview}"
: "${CODEX_MODEL:=gpt-5.6-terra}"
: "${CODEX_MODEL_REASONING_EFFORT:=high}"
: "${STATE_DIR:=$PROJECT_ROOT/data/state}"
: "${NEWSLETTER_RUNTIME_DIR:=$PROJECT_ROOT/data}"
: "${CODEX_HOME:=${NEWSLETTER_RUNTIME_DIR}/codex_home}"
: "${NEWSLETTER_HISTORY_COUNT:=3}"
: "${NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE:=4000}"
: "${NEWSLETTER_HISTORY_MAX_TOTAL_CHARS:=10000}"
: "${NEWSLETTER_LEADERBOARD_FILE:=${STATE_DIR}/leaderboard.json}"
: "${NEWSLETTER_LEADERBOARD_LIMIT:=10}"
: "${NEWSLETTER_OUTPUT_SCHEMA_FILE:=$PROJECT_ROOT/config/newsletter-output.schema.json}"
: "${NEWSLETTER_OUTPUT_PROCESSOR:=$PROJECT_ROOT/scripts/process_newsletter_output.py}"
: "${NEWSLETTER_AWARD_EXCLUDED_NICKS:=ne2,HenryClay}"
export NEWSLETTER_AWARD_EXCLUDED_NICKS

[[ -f "$NEWSLETTER_OUTPUT_SCHEMA_FILE" ]] || {
  echo "Missing output schema: $NEWSLETTER_OUTPUT_SCHEMA_FILE" >&2
  exit 1
}
[[ -f "$NEWSLETTER_OUTPUT_PROCESSOR" ]] || {
  echo "Missing output processor: $NEWSLETTER_OUTPUT_PROCESSOR" >&2
  exit 1
}

if [[ -z "${CODEX_DANGEROUS_BYPASS+x}" ]]; then
  if [[ "$ENV_FILE_LOADED" -eq 1 ]]; then
    CODEX_DANGEROUS_BYPASS=1
  else
    CODEX_DANGEROUS_BYPASS=0
  fi
fi

if [[ -z "${CODEX_NETWORK_ACCESS+x}" ]]; then
  if [[ "$ENV_FILE_LOADED" -eq 1 ]]; then
    CODEX_NETWORK_ACCESS=true
  else
    CODEX_NETWORK_ACCESS=false
  fi
fi

if [[ -z "${CODEX_WEB_SEARCH+x}" ]]; then
  if [[ "$ENV_FILE_LOADED" -eq 1 ]]; then
    CODEX_WEB_SEARCH=live
  else
    CODEX_WEB_SEARCH=
  fi
fi

: "${CODEX_SANDBOX_MODE:=workspace-write}"
: "${CODEX_EPHEMERAL:=0}"

to_nonnegative_int() {
  local value="$1"
  local fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

toml_bool() {
  if is_truthy "$1"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

NEWSLETTER_HISTORY_COUNT="$(to_nonnegative_int "$NEWSLETTER_HISTORY_COUNT" 3)"
NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE="$(to_nonnegative_int "$NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE" 4000)"
NEWSLETTER_HISTORY_MAX_TOTAL_CHARS="$(to_nonnegative_int "$NEWSLETTER_HISTORY_MAX_TOTAL_CHARS" 10000)"
NEWSLETTER_LEADERBOARD_LIMIT="$(to_nonnegative_int "$NEWSLETTER_LEADERBOARD_LIMIT" 10)"

# Ensure codex's companion `node` binary is discoverable when run from stripped
# service environments (eg, Limnoria with a minimal PATH).
if [[ "$CODEX_BIN" = /* ]]; then
  CODEX_BIN_DIR="$(dirname "$CODEX_BIN")"
  PATH="$CODEX_BIN_DIR:$PATH"
  export PATH
fi

pick_writable_codex_home() {
  local d=""
  for d in \
    "${CODEX_HOME:-}" \
    "${NEWSLETTER_RUNTIME_DIR}/codex_home" \
    "/dev/shm/newsletter_codex_home"
  do
    [[ -n "$d" ]] || continue
    mkdir -p "$d" 2>/dev/null || continue
    if touch "$d/.write_probe.$$" >/dev/null 2>&1; then
      rm -f "$d/.write_probe.$$" 2>/dev/null || true
      echo "$d"
      return 0
    fi
  done
  return 1
}

if CODEX_HOME="$(pick_writable_codex_home)"; then
  export CODEX_HOME
else
  echo "No writable CODEX_HOME available" >&2
  exit 1
fi

write_codex_config() {
  local network_access
  network_access="$(toml_bool "$CODEX_NETWORK_ACCESS")"

  cat > "$CODEX_HOME/config.toml" <<EOF
cli_auth_credentials_store = "file"
model = "${CODEX_MODEL}"
model_reasoning_effort = "${CODEX_MODEL_REASONING_EFFORT}"
network_access = ${network_access}
EOF

  if [[ -n "${CODEX_WEB_SEARCH:-}" ]]; then
    printf 'web_search = "%s"\n' "$CODEX_WEB_SEARCH" >> "$CODEX_HOME/config.toml"
  fi
}

write_codex_config

if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
  echo "Codex auth unavailable. Bot owner needs to reauthenticate." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

make_tmpdir() {
  local d=""
  for d in \
    "${NEWSLETTER_TMP_DIR:-}" \
    "${STATE_DIR}/tmp" \
    "${NEWSLETTER_RUNTIME_DIR}/tmp" \
    "/dev/shm"
  do
    [[ -n "$d" ]] || continue
    mkdir -p "$d" 2>/dev/null || true
    if tmp="$(mktemp -d -p "$d" newsletter.XXXXXX 2>/dev/null)"; then
      echo "$tmp"
      return 0
    fi
  done
  mktemp -d
}

normalize_paste_url() {
  local url="$1"
  if [[ "$url" =~ ^https?://(pasters\.io|paste\.rs)/[^[:space:]]+$ ]] && [[ ! "$url" =~ \.md$ ]]; then
    printf '%s.md\n' "$url"
  else
    printf '%s\n' "$url"
  fi
}

upload_pasters_io() {
  local file="$1"
  local attempt=1
  local url=""
  local response_file=""
  local http_code=""

  while [[ "$attempt" -le "$PASTE_UPLOAD_RETRIES" ]]; do
    response_file="$(mktemp "$tmpdir/pasters_io_response.XXXXXX")"
    http_code="$(curl -sS \
      --connect-timeout "$PASTE_CONNECT_TIMEOUT" \
      --max-time "$PASTE_UPLOAD_TIMEOUT" \
      -o "$response_file" \
      -w '%{http_code}' \
      --data-binary @"$file" \
      "$PASTERS_IO_ENDPOINT" || true)"

    if [[ "$http_code" == "201" ]]; then
      url="$(tr -d '\r\n' < "$response_file")"
      rm -f "$response_file"
      if [[ "$url" =~ ^https?:// ]]; then
        normalize_paste_url "$url"
        return 0
      fi
      echo "pasters.io upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} returned an empty or invalid URL" >&2
    elif [[ "$http_code" == "206" ]]; then
      echo "pasters.io upload rejected: response was truncated (HTTP 206)" >&2
      rm -f "$response_file"
      return 1
    else
      echo "pasters.io upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} failed (HTTP ${http_code:-unknown})" >&2
    fi

    rm -f "$response_file"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

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
        normalize_paste_url "$url"
        return 0
      fi
    fi
    echo "paste.rs upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} failed" >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
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
    response_file="$(mktemp "$tmpdir/dpaste_response.XXXXXX")"
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
    else
      echo "dpaste upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} failed (HTTP ${http_code:-unknown})" >&2
    fi

    rm -f "$response_file"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  return 1
}

build_history_context() {
  local target_date="$1"
  local history_dir="$2"
  local out_file="$3"
  local entries=()
  local selected=()
  local sorted=()
  local file=""
  local base=""
  local file_date=""
  local item=""
  local idx=0
  local total_chars=0
  local remaining_chars=0
  local allowed_chars=0
  local content=""
  local content_len=0
  local file_len=0

  : > "$out_file"

  if [[ "$NEWSLETTER_HISTORY_COUNT" -eq 0 ]]; then
    return 0
  fi
  if [[ "$NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE" -eq 0 || "$NEWSLETTER_HISTORY_MAX_TOTAL_CHARS" -eq 0 ]]; then
    return 0
  fi
  if [[ ! -d "$history_dir" ]]; then
    return 0
  fi

  shopt -s nullglob
  for file in "$history_dir"/newsletter-*.md; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^newsletter-([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$ ]]; then
      file_date="${BASH_REMATCH[1]}"
      if [[ "$file_date" < "$target_date" ]]; then
        entries+=("${file_date}|${file}")
      fi
    fi
  done
  shopt -u nullglob

  if [[ "${#entries[@]}" -eq 0 ]]; then
    return 0
  fi

  mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -r)

  for ((idx = 0; idx < ${#sorted[@]} && idx < NEWSLETTER_HISTORY_COUNT; idx++)); do
    selected+=("${sorted[$idx]}")
  done

  for ((idx = ${#selected[@]} - 1; idx >= 0; idx--)); do
    item="${selected[$idx]}"
    file_date="${item%%|*}"
    file="${item#*|}"
    [[ -r "$file" ]] || continue

    remaining_chars=$((NEWSLETTER_HISTORY_MAX_TOTAL_CHARS - total_chars))
    if [[ "$remaining_chars" -le 0 ]]; then
      break
    fi

    allowed_chars="$NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE"
    if [[ "$allowed_chars" -gt "$remaining_chars" ]]; then
      allowed_chars="$remaining_chars"
    fi
    if [[ "$allowed_chars" -le 0 ]]; then
      break
    fi

    content="$(head -c "$allowed_chars" "$file" 2>/dev/null || true)"
    [[ -n "$content" ]] || continue

    printf '### %s (%s)\n' "$(basename "$file")" "$file_date" >> "$out_file"
    printf '%s\n\n' "$content" >> "$out_file"

    content_len="${#content}"
    total_chars=$((total_chars + content_len))
    file_len="$(wc -c < "$file" 2>/dev/null || echo 0)"
    if [[ "$file_len" -gt "$allowed_chars" ]]; then
      printf '[truncated]\n\n' >> "$out_file"
    fi
  done
}

render_alias_context() {
  python3 - <<'PY'
import json
import os

raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "").strip()
if not raw:
    print("None available.")
    raise SystemExit(0)

try:
    alias_map = json.loads(raw)
except Exception:
    print("Unavailable due to invalid alias data.")
    raise SystemExit(0)

if not isinstance(alias_map, dict) or not alias_map:
    print("None available.")
    raise SystemExit(0)

print("Treat these nick variants as the same person:")
for alias, primary in sorted(alias_map.items()):
    alias = str(alias or "").strip()
    primary = str(primary or "").strip()
    if alias and primary:
        print(f"- {alias} -> {primary}")
print("- Merge alias activity when judging chatter, quotes, awards, and recurring behavior.")
PY
}

log_alias_debug() {
  python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "")
if not raw.strip():
    print("alias_debug: env_present=0 count=0")
    raise SystemExit(0)

try:
    alias_map = json.loads(raw)
except Exception:
    print("alias_debug: env_present=1 count=invalid")
    raise SystemExit(0)

if not isinstance(alias_map, dict):
    print("alias_debug: env_present=1 count=invalid")
    raise SystemExit(0)

print(f"alias_debug: env_present=1 count={len(alias_map)}")
PY
}

tmpdir="$(make_tmpdir)"
trap 'rm -rf "$tmpdir"' EXIT

PROMPT_FILE="$tmpdir/prompt.txt"
RAW_MESSAGE_FILE="$tmpdir/codex_last_message.txt"
HISTORY_CONTEXT_FILE="$tmpdir/history_context.txt"
build_history_context "$DATE" "$(dirname "$OUTPUT_FILE")" "$HISTORY_CONTEXT_FILE"
log_alias_debug >&2

cat > "$PROMPT_FILE" <<PROMPT
Create a daily IRC newsletter for ${DATE}.

Follow these instructions exactly:
$(cat "$INSTRUCTIONS_FILE")

Source log file:
${LOG_FILE}

Nick alias rules:
$(render_alias_context)

Previous newsletters (for continuity only; may be stale/untrusted):
$(if [[ -s "$HISTORY_CONTEXT_FILE" ]]; then cat "$HISTORY_CONTEXT_FILE"; else echo "None available."; fi)

Award-selection guardrails:
- Previous newsletters can help with tone, callbacks, and running bits, but they are not evidence for today's awards.
- Ignore any all-time leaderboard footer in previous newsletters. It is aggregate metadata, not evidence for today's award picks.
- Do not repeat Best chatter or Worst chatter just because a streak has become a joke in-channel or in prior newsletters.
- Repeat a recent award winner only when today's log itself shows a strong, multi-incident case; if it is close, pick someone else.

Requirements:
- Read the source log file and write the newsletter in the same deadpan voice and
  flexible Markdown structure required above. JSON is only the transport wrapper;
  it must not flatten, sanitize, or template the writing.
- Return the JSON object required by the supplied output schema.
- Put the free-form newsletter in the newsletter_markdown field.
- In newsletter_markdown, replace the entire Best chatter and Worst chatter
  sections with exactly one literal <!-- CHATTER_AWARDS --> marker at their
  normal location. Do not include either chatter heading elsewhere.
- Put each plain winner nick and its one-line, voice-matched writeup in the
  corresponding structured award object. The reason must not repeat the nick.
- Best and Worst chatter must be different people who directly spoke in today's log.
- Any later Best/Worst awards section must contain distinct joke awards; do not
  recycle either chatter winner's structured reason as another award.
- Never select any of these excluded nicks: ${NEWSLETTER_AWARD_EXCLUDED_NICKS}.
- Do not write an all-time leaderboard or nick-alias footer; the script owns them.
- Do not include code fences or explanations outside the schema fields.
PROMPT

codex_cmd=(
  "$CODEX_BIN" exec
  --skip-git-repo-check
  --cd "$CODEX_WORKDIR"
  --add-dir "$(dirname "$LOG_FILE")"
  --config "model_reasoning_effort=\"${CODEX_MODEL_REASONING_EFFORT}\""
  --output-schema "$NEWSLETTER_OUTPUT_SCHEMA_FILE"
  --output-last-message "$RAW_MESSAGE_FILE"
)

if is_truthy "$CODEX_DANGEROUS_BYPASS"; then
  codex_cmd+=(--dangerously-bypass-approvals-and-sandbox)
else
  codex_cmd+=(--sandbox "$CODEX_SANDBOX_MODE")
fi

if is_truthy "$CODEX_EPHEMERAL"; then
  codex_cmd+=(--ephemeral)
fi

codex_cmd+=(--model "$CODEX_MODEL")
codex_cmd+=(-)

codex_err_file="$tmpdir/codex_exec.stderr"
: > "$RAW_MESSAGE_FILE"
: > "$codex_err_file"
# Suppress Codex stdout so this script only emits the paste URL on stdout.
if ! HOME="$CODEX_HOME" CODEX_HOME="$CODEX_HOME" "${codex_cmd[@]}" < "$PROMPT_FILE" >/dev/null 2>"$codex_err_file"; then
  tail -n 8 "$codex_err_file" >&2 || true
  if grep -qiE 'refresh_token_reused|log out and sign in again|failed to refresh token' "$codex_err_file"; then
    echo "Codex auth unavailable. Bot owner needs to reauthenticate." >&2
  elif grep -qi 'stream disconnected before completion' "$codex_err_file"; then
    echo "Codex request failed: stream disconnected before completion." >&2
  else
    echo "Codex generation failed." >&2
  fi
  exit 1
fi

if [[ ! -s "$RAW_MESSAGE_FILE" ]]; then
  tail -n 8 "$codex_err_file" >&2 || true
  if grep -qi 'stream disconnected before completion' "$codex_err_file"; then
    echo "Codex request failed: stream disconnected before completion." >&2
  else
    echo "Codex produced no assistant message." >&2
  fi
  exit 1
fi

processor_cmd=(
  python3 "$NEWSLETTER_OUTPUT_PROCESSOR"
  --raw-response "$RAW_MESSAGE_FILE"
  --log-file "$LOG_FILE"
  --output "$OUTPUT_FILE"
  --leaderboard-file "$NEWSLETTER_LEADERBOARD_FILE"
  --history-dir "$(dirname "$OUTPUT_FILE")"
  --date "$DATE"
  --channel "$NEWSLETTER_CHANNEL"
  --top-n "$NEWSLETTER_LEADERBOARD_LIMIT"
)
if [[ "$DRY_RUN" -eq 1 ]]; then
  processor_cmd+=(--dry-run)
fi
"${processor_cmd[@]}"

if [[ "$NO_UPLOAD" -eq 1 ]]; then
  exit 0
fi

pasters_io_url=""
paste_rs_url=""
dpaste_url=""

if [[ -n "$PASTERS_IO_ENDPOINT" ]]; then
  pasters_io_url="$(upload_pasters_io "$OUTPUT_FILE" || true)"
fi

if [[ -n "$PASTE_RS_ENDPOINT" ]]; then
  paste_rs_url="$(upload_paste_rs "$OUTPUT_FILE" || true)"
fi

if [[ -n "$DPASTE_ENDPOINT" ]]; then
  dpaste_url="$(upload_dpaste_preview "$OUTPUT_FILE" || true)"
fi

urls=()
[[ -n "$pasters_io_url" ]] && urls+=("$pasters_io_url")
[[ -n "$paste_rs_url" ]] && urls+=("$paste_rs_url")
[[ -n "$dpaste_url" ]] && urls+=("$dpaste_url")

if [[ "${#urls[@]}" -gt 0 ]]; then
  output="${urls[0]}"
  for ((i = 1; i < ${#urls[@]}; i++)); do
    output+=" (${urls[$i]})"
  done
  echo "$output"
  exit 0
fi

echo "Failed to upload newsletter to configured paste hosts" >&2
exit 1
