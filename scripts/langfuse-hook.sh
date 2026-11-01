#!/bin/bash
# Hook Stop do Antigravity CLI (agy) -> Langfuse OTLP HTTP JSON (/api/public/otel/v1/traces)
# Compatível com Langfuse v4 (events_only) e v3, utilizando apenas bash + jq + curl.
set -uo pipefail

finish() {
  echo "{}"
  exit 0
}

PAYLOAD="$(cat 2>/dev/null || true)"
[[ -n "$PAYLOAD" ]] || finish

PUB_KEY="${LANGFUSE_PUBLIC_KEY:-}"
SEC_KEY="${LANGFUSE_SECRET_KEY:-}"
HOST="${LANGFUSE_BASE_URL:-${LANGFUSE_HOST:-https://cloud.langfuse.com}}"
HOST="${HOST%/}"

[[ -n "$PUB_KEY" && -n "$SEC_KEY" && -n "$HOST" ]] || finish

CONV_ID="$(jq -r '.conversationId // empty' <<<"$PAYLOAD" 2>/dev/null || true)"
TRANSCRIPT_PATH="$(jq -r '.transcriptPath // empty' <<<"$PAYLOAD" 2>/dev/null || true)"
MODEL_NAME="$(jq -r '.modelName // "antigravity"' <<<"$PAYLOAD" 2>/dev/null || echo "antigravity")"
WORKSPACES_JSON="$(jq -c '.workspacePaths // []' <<<"$PAYLOAD" 2>/dev/null || echo "[]")"

[[ -n "$CONV_ID" && -n "$TRANSCRIPT_PATH" ]] || finish

TRANSCRIPT_DIR="$(dirname "$TRANSCRIPT_PATH")"
if [[ -f "$TRANSCRIPT_DIR/transcript_full.jsonl" ]]; then
  T_FILE="$TRANSCRIPT_DIR/transcript_full.jsonl"
elif [[ -f "$TRANSCRIPT_PATH" ]]; then
  T_FILE="$TRANSCRIPT_PATH"
else
  finish
fi

STATE_FILE="$TRANSCRIPT_DIR/.langfuse_offset"
LAST_IDX=-1
if [[ -f "$STATE_FILE" ]]; then
  RAW_IDX="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || true)"
  [[ "$RAW_IDX" =~ ^-?[0-9]+$ ]] && LAST_IDX="$RAW_IDX"
fi

co_author="${GIT_CO_AUTHOR:-}"
co_author="${co_author##*<}"
co_author="${co_author%%>*}"
USER_ID="${LANGFUSE_USER_ID:-${co_author:-${GIT_USER_EMAIL:-${GIT_USER_NAME:-${USER:-agent}}}}}"

RAW_TAGS="${AGY_LANGFUSE_TRACE_TAGS:-${CC_LANGFUSE_TRACE_TAGS:-}}"
MAX_CHARS="${AGY_LANGFUSE_MAX_CHARS:-${CC_LANGFUSE_MAX_CHARS:-20000}}"
[[ "$MAX_CHARS" =~ ^[0-9]+$ ]] || MAX_CHARS=20000
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Trace ID base (32 hex chars a partir do UUID da conversa)
TRACE_HEX="$(tr -cd '0-9a-fA-F' <<<"$CONV_ID" | tr 'A-F' 'a-f')"
if [[ "${#TRACE_HEX}" -lt 32 ]]; then
  TRACE_HEX="$(printf '%s00000000000000000000000000000000' "$TRACE_HEX" | cut -c1-32)"
else
  TRACE_HEX="${TRACE_HEX:0:32}"
fi

TMP_OTLP="$(mktemp /tmp/langfuse-otlp.XXXXXX.json 2>/dev/null || echo "/tmp/langfuse-otlp-$$.json")"
trap 'rm -f "$TMP_OTLP"' EXIT

MAX_IDX="$(jq -s -r \
  --arg conv_id "$CONV_ID" \
  --arg trace_id "$TRACE_HEX" \
  --arg model_name "$MODEL_NAME" \
  --arg user_id "$USER_ID" \
  --arg now_iso "$NOW_ISO" \
  --arg raw_tags "$RAW_TAGS" \
  --arg git_branch "${GIT_BRANCH:-}" \
  --arg git_repo "${GIT_REPO_URL:-}" \
  --arg issue_id "${ISSUE_ID:-}" \
  --arg hostname "${HOSTNAME:-}" \
  --argjson workspaces "$WORKSPACES_JSON" \
  --argjson last_idx "$LAST_IDX" \
  --argjson max_chars "$MAX_CHARS" \
  '
  def trunc:
    if type == "string" and (length > $max_chars) then
      .[:$max_chars] + "...[truncated]"
    else
      .
    end;

  def iso_to_nano:
    (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch now) * 1000000000 | floor | tostring;

  def hex8($n):
    ([((($n / 268435456) | floor) % 16),
      ((($n / 16777216)  | floor) % 16),
      ((($n / 1048576)   | floor) % 16),
      ((($n / 65536)     | floor) % 16),
      ((($n / 4096)      | floor) % 16),
      ((($n / 256)       | floor) % 16),
      ((($n / 16)        | floor) % 16),
      (($n | floor) % 16)]
     | map("0123456789abcdef"[.:.+1]) | join(""));

  def kv_str($k; $v):
    { key: $k, value: { stringValue: ($v | tostring) } };

  def kv_arr($k; $arr):
    { key: $k, value: { arrayValue: { values: ($arr | map({ stringValue: tostring })) } } };

  ([.[] | select((.step_index // -1) > $last_idx)]) as $new_steps
  | if ($new_steps | length) == 0 then
      empty
    else
      ((["antigravity", "agy-cli"] + ($raw_tags | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))) | unique) as $tags
      | ([.[] | select(.type == "USER_INPUT") | (.content // empty | trunc)] | last // "") as $latest_user_input
      | ([$new_steps[] | select(.type == "PLANNER_RESPONSE") | (.content // empty | trunc) | select(length > 0)] | last // "") as $latest_output
      | ($new_steps | map(.step_index // 0) | min) as $min_idx
      | ($new_steps | map(.step_index // 0) | max) as $max_idx
      | ($trace_id[0:24] + hex8($min_idx)) as $turn_trace_id
      | ($trace_id[0:4] + $trace_id[28:32]) as $span_prefix
      | ($span_prefix + "1" + (hex8($min_idx)[1:8])) as $root_span_id
      | (($new_steps[0].created_at // $now_iso) | iso_to_nano) as $turn_start_nano
      | (($new_steps[-1].created_at // $now_iso) | iso_to_nano) as $turn_end_nano
      | {
          max_idx: $max_idx,
          otlp: {
            resourceSpans: [
              {
                resource: {
                  attributes: [
                    kv_str("service.name"; "antigravity-cli"),
                    kv_str("host.name"; $hostname)
                  ]
                },
                scopeSpans: [
                  {
                    scope: {
                      name: "langfuse-sdk",
                      version: "4.18.0"
                    },
                    spans: (
                      [
                        {
                          traceId: $turn_trace_id,
                          spanId: $root_span_id,
                          name: "Conversational Turn",
                          kind: 1,
                          startTimeUnixNano: $turn_start_nano,
                          endTimeUnixNano: $turn_end_nano,
                          attributes: [
                            kv_str("langfuse.observation.type"; "span"),
                            kv_str("langfuse.trace.name"; "Conversational Turn"),
                            kv_str("user.id"; $user_id),
                            kv_str("session.id"; $conv_id),
                            kv_arr("langfuse.trace.tags"; $tags),
                            kv_str("langfuse.observation.input"; ({role: "user", content: $latest_user_input} | tojson)),
                            kv_str("langfuse.observation.output"; ({role: "assistant", content: $latest_output} | tojson)),
                            kv_str("langfuse.observation.metadata.source"; "antigravity-cli"),
                            kv_str("langfuse.observation.metadata.git_branch"; $git_branch),
                            kv_str("langfuse.observation.metadata.git_repo_url"; $git_repo),
                            kv_str("langfuse.observation.metadata.issue_id"; $issue_id),
                            kv_str("langfuse.observation.metadata.workspaces"; ($workspaces | tojson))
                          ]
                        }
                      ]
                      + (
                        reduce $new_steps[] as $s (
                          { spans: [], last_input: $latest_user_input, prev_ts_nano: $turn_start_nano };
                          ($s.step_index // 0) as $idx
                          | ($s.type // "UNKNOWN") as $stype
                          | (($s.created_at // $now_iso) | iso_to_nano) as $ts_nano
                          | (if ($ts_nano | tonumber) >= (.prev_ts_nano | tonumber) then .prev_ts_nano else $ts_nano end) as $start_nano
                          | ($span_prefix + "2" + (hex8($idx)[1:8])) as $step_span_id
                          | if $stype == "USER_INPUT" then
                              .last_input = (($s.content // "") | trunc)
                              | .prev_ts_nano = $ts_nano
                            elif $stype == "PLANNER_RESPONSE" then
                              ($s.input_tokens // 0) as $in_tok
                              | ($s.cache_read_tokens // 0) as $cache_tok
                              | ($s.output_tokens // 0) as $out_tok
                              | .spans += [
                                  {
                                    traceId: $turn_trace_id,
                                    spanId: $step_span_id,
                                    parentSpanId: $root_span_id,
                                    name: "LLM Call",
                                    kind: 1,
                                    startTimeUnixNano: $start_nano,
                                    endTimeUnixNano: $ts_nano,
                                    attributes: [
                                      kv_str("langfuse.observation.type"; "generation"),
                                      kv_str("langfuse.observation.model.name"; $model_name),
                                      kv_str("langfuse.observation.usage_details"; ({
                                        input: $in_tok,
                                        output: $out_tok,
                                        cache_read_input_tokens: $cache_tok,
                                        total: ($in_tok + $cache_tok + $out_tok)
                                      } | tojson)),
                                      kv_str("langfuse.observation.input"; ({role: "user", content: .last_input} | tojson)),
                                      kv_str("langfuse.observation.output"; ({
                                        content: (($s.content // "") | trunc),
                                        thinking: (($s.thinking // "") | trunc),
                                        tool_calls: ($s.tool_calls // [])
                                      } | tojson)),
                                      kv_str("langfuse.observation.metadata.step_index"; ($idx | tostring)),
                                      kv_str("langfuse.observation.metadata.status"; ($s.status // "DONE")),
                                      kv_str("user.id"; $user_id),
                                      kv_str("session.id"; $conv_id)
                                    ]
                                  }
                                ]
                              | .prev_ts_nano = $ts_nano
                            else
                              .spans += [
                                  {
                                    traceId: $turn_trace_id,
                                    spanId: $step_span_id,
                                    parentSpanId: $root_span_id,
                                    name: ("Tool Result (" + ($stype | ascii_downcase) + ")"),
                                    kind: 1,
                                    startTimeUnixNano: $start_nano,
                                    endTimeUnixNano: $ts_nano,
                                    attributes: [
                                      kv_str("langfuse.observation.type"; "span"),
                                      kv_str("langfuse.observation.output"; (($s.content // "") | trunc | tojson)),
                                      kv_str("langfuse.observation.metadata.step_index"; ($idx | tostring)),
                                      kv_str("langfuse.observation.metadata.source"; ($s.source // "")),
                                      kv_str("langfuse.observation.metadata.status"; ($s.status // "")),
                                      kv_str("user.id"; $user_id),
                                      kv_str("session.id"; $conv_id)
                                    ]
                                  }
                                ]
                              | .prev_ts_nano = $ts_nano
                            end
                        ) | .spans
                      )
                    )
                  }
                ]
              }
            ]
          }
        }
      | (.max_idx | tostring), (.otlp | tojson)
    end
  ' "$T_FILE" 2>/dev/null | {
    read -r max_idx || exit 0
    cat > "$TMP_OTLP"
    printf '%s' "$max_idx"
  })"

[[ -n "$MAX_IDX" && -s "$TMP_OTLP" ]] || finish

HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
  -u "${PUB_KEY}:${SEC_KEY}" \
  -H "Content-Type: application/json" \
  -X POST "${HOST}/api/public/otel/v1/traces" \
  --data-binary "@$TMP_OTLP" 2>/dev/null || echo "000")"

if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
  printf '%s\n' "$MAX_IDX" > "$STATE_FILE" 2>/dev/null || true
fi

finish
