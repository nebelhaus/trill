#!/usr/bin/env bash
#
# beeper-contract-check.sh — validate Trill's Beeper adapter against a real
# headless Beeper Server.
#
# ADR 0004 records that the adapter's contract was derived from the official
# @beeper/desktop-api 5.0.0 TypeScript types and has never seen a response from
# a running Server. This script closes that gap: it calls exactly the endpoints
# BeeperClient calls, with exactly the parameters it sends, and reports
#
#   - the Server's app.version           (what §5's ship gate asks to record)
#   - which fields BeeperMapper depends on are actually present, and how often
#   - any field the Server returns that BeeperDTOs.swift doesn't model
#   - whether Beeper's own iMessage account is excluded by the accountIDs filter
#
# It never prints a value from a message, chat, contact or account — only field
# names, JSON types and counts. The report it writes is safe to paste into an
# issue or a chat; a raw capture of this API never is (docs/security.md).
#
# Read-only: every request is a GET except /v1/assets/download, which this
# script does not call.
#
# Usage:
#   scripts/beeper-contract-check.sh [--out DIR]
#
#   BEEPER_ENDPOINT   default http://127.0.0.1:23373
#   BEEPER_TOKEN      default: read from the same Keychain item Trill uses
#                     (service com.nebelhaus.trill, account beeper.accessToken)

set -euo pipefail

ENDPOINT="${BEEPER_ENDPOINT:-http://127.0.0.1:23373}"
OUT_DIR="${TMPDIR:-/tmp}/trill-beeper-contract"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

TOKEN="${BEEPER_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TOKEN="$(security find-generic-password -s com.nebelhaus.trill \
             -a beeper.accessToken -w 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ]; then
  cat >&2 <<'EOF'
No token. Either export BEEPER_TOKEN, or store it where Trill reads it:

  security add-generic-password -U -s com.nebelhaus.trill \
    -a beeper.accessToken -w '<token from Beeper → Settings → Advanced → API>'
EOF
  exit 1
fi

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.txt"
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
rule() { say ""; say "── $* ─────────────────────────────────────────" ; }

# Values become their JSON type; only field names survive. `seen` is a map keyed
# by user ID, so its keys are elided too — everywhere else keys are static.
JQ_SHAPE='
def shape:
  if type == "object" then
    with_entries(
      if .key == "seen"
      then .value = "<\(.value|type), keys elided>"
      else .value |= shape end)
  elif type == "array" then
    if length == 0 then "[] (0)" else ["array(\(length))", (.[0]|shape)] end
  elif type == "null" then "null"
  else type end;
'

# Fields BeeperMapper reads today. Keep in sync with BeeperMapper.swift.
CHAT_FIELDS='id accountID network title type unreadCount participants lastActivity preview'
MESSAGE_FIELDS='id accountID chatID senderID sortKey timestamp text type senderName isSender isUnread isDeleted isHidden editedTimestamp linkedMessageID attachments reactions seen sendStatus'
ACCOUNT_FIELDS='accountID bridge user network'
USER_FIELDS='id fullName username phoneNumber email imgURL isSelf'

# Decoded but not consumed until §3/§4 — reported for information, not as a defect.
CHAT_LATER_FIELDS='capabilities isArchived isMuted isPinned isReadOnly'

# Every key BeeperDTOs.swift models, per type — anything else is drift worth knowing.
CHAT_KNOWN="$CHAT_FIELDS $CHAT_LATER_FIELDS localChatID isMarkedUnread unreadMentionsCount lastReadMessageSortKey imgURL description"
MESSAGE_KNOWN="$MESSAGE_FIELDS"
ACCOUNT_KNOWN="$ACCOUNT_FIELDS"
USER_KNOWN="$USER_FIELDS cannotMessage"

# api PATH [QUERYSTRING] — sets $RESP (body) and $HTTP_STATUS. Not a subshell,
# because the status has to survive the call. The body lands in a temp file that
# is deleted on exit: it holds real messages and must not outlive the run.
BODY_FILE="$(mktemp -t trill-beeper)"
trap 'rm -f "$BODY_FILE"' EXIT
HTTP_STATUS=""
RESP=""
api() {
  local path="$1" query="${2:-}" url
  url="$ENDPOINT$path"
  if [ -n "$query" ]; then url="$url?$query"; fi
  # curl writes `000` itself when it never got a response; `|| true` is only so
  # its non-zero exit doesn't trip `set -e` at the assignment.
  HTTP_STATUS="$(curl -sS -m 20 -o "$BODY_FILE" -w '%{http_code}' \
                   -H "Authorization: Bearer $TOKEN" \
                   -H 'Accept: application/json' "$url" 2>/dev/null || true)"
  HTTP_STATUS="${HTTP_STATUS:-000}"
  RESP="$(cat "$BODY_FILE" 2>/dev/null || true)"
}

# presence ITEMS_JSON "field ..." — how many items carry each field non-null.
presence() {
  local items="$1" fields="$2" total
  total="$(printf '%s' "$items" | jq 'length')"
  say "  $total item(s) sampled"
  for f in $fields; do
    local n
    n="$(printf '%s' "$items" | jq --arg f "$f" '[.[] | select(.[$f] != null)] | length')"
    if [ "$n" = "0" ] && [ "$total" != "0" ]; then
      say "  · $f: absent in all $total  ←"
    else
      say "  · $f: $n/$total"
    fi
  done
}

# extras ITEMS_JSON "known ..." — keys the Server sends that we don't model.
extras() {
  local items="$1" known="$2" found
  found="$(printf '%s' "$items" \
    | jq -r --arg known "$known" '
        ($known | split(" ")) as $k
        | [.[] | keys[]] | unique | map(select(. as $x | ($k | index($x)) | not)) | join(", ")')"
  if [ -n "$found" ]; then
    say "  ! unmodelled keys: $found"
  else
    say "  ✓ no unmodelled keys"
  fi
}

shape_of() {
  printf '%s' "$1" | jq "$JQ_SHAPE"' .[0] // {} | shape' 2>/dev/null \
    | sed 's/^/    /' | tee -a "$REPORT" || true
}

say "Trill ↔ Beeper contract check"
say "endpoint: $ENDPOINT"

# ── /v1/info ────────────────────────────────────────────────────────────────
rule "GET /v1/info"
api /v1/info
INFO="$RESP"
if [ "$HTTP_STATUS" != "200" ]; then
  say "  HTTP $HTTP_STATUS"
  say ""
  case "$HTTP_STATUS" in
    000) say "  Nothing answered on $ENDPOINT. Start the Server:"
         say "      beeper --server --install" ;;
    401|403) say "  The token was rejected. Re-copy it from Beeper →" \
                 "Settings → Advanced → API." ;;
    *) say "  Unexpected status from /v1/info — check the Server's own logs." ;;
  esac
  exit 1
fi
APP_VERSION="$(printf '%s' "$INFO" | jq -r '.app.version // "unknown"')"
say "  app.name         $(printf '%s' "$INFO" | jq -r '.app.name // "?"')"
say "  app.version      $APP_VERSION      ← record this in ADR 0004"
say "  app.bundle_id    $(printf '%s' "$INFO" | jq -r '.app.bundle_id // "?"')"
say "  server.status    $(printf '%s' "$INFO" | jq -r '.server.status // "?"')"
say "  endpoints.spec   $(printf '%s' "$INFO" | jq -r '.endpoints.spec // "?"')"
say "  ws_events        $(printf '%s' "$INFO" | jq -r '.endpoints.ws_events // "?"')"

SPEC_URL="$(printf '%s' "$INFO" | jq -r '.endpoints.spec // empty')"
if [ -n "$SPEC_URL" ]; then
  case "$SPEC_URL" in /*) SPEC_URL="$ENDPOINT$SPEC_URL" ;; esac
  if curl -sS -m 20 -H "Authorization: Bearer $TOKEN" "$SPEC_URL" \
       -o "$OUT_DIR/openapi.json" 2>/dev/null; then
    say "  spec saved       $OUT_DIR/openapi.json (no user data — the API document)"
  fi
fi

# ── /v1/accounts ────────────────────────────────────────────────────────────
rule "GET /v1/accounts"
api /v1/accounts
ACCOUNTS="$RESP"
say "  HTTP $HTTP_STATUS"
[ "$HTTP_STATUS" = "200" ] || exit 1
# accountID can embed a team/user id, so it is counted, never printed.
say "  accounts: $(printf '%s' "$ACCOUNTS" | jq 'length')"
printf '%s' "$ACCOUNTS" | jq -r '.[] | "  · bridge.type=\(.bridge.type) provider=\(.bridge.provider // "?") network=\(.network // "?")"' | tee -a "$REPORT"
presence "$ACCOUNTS" "$ACCOUNT_FIELDS"
extras "$ACCOUNTS" "$ACCOUNT_KNOWN"

# BeeperProvider's rule: an account is iMessage when accountID or bridge.type contains "imessage".
IMESSAGE_N="$(printf '%s' "$ACCOUNTS" | jq '[.[] | select((.accountID|ascii_downcase|contains("imessage")) or (.bridge.type|ascii_downcase|contains("imessage")))] | length')"
say "  iMessage accounts excluded by the allowlist: $IMESSAGE_N"
ALLOWED="$(printf '%s' "$ACCOUNTS" | jq -r '.[] | select(((.accountID|ascii_downcase|contains("imessage")) or (.bridge.type|ascii_downcase|contains("imessage"))) | not) | .accountID')"
if [ -z "$ALLOWED" ]; then
  say "  ! every account is iMessage — the adapter would show nothing. Stop here."
  exit 1
fi
QUERY_ACCOUNTS=""
while IFS= read -r a; do
  [ -z "$a" ] && continue
  enc="$(jq -rn --arg v "$a" '$v|@uri')"
  QUERY_ACCOUNTS="$QUERY_ACCOUNTS&accountIDs=$enc"
done <<EOF
$ALLOWED
EOF
QUERY_ACCOUNTS="${QUERY_ACCOUNTS#&}"
FIRST_ACCOUNT="$(printf '%s' "$ALLOWED" | head -1)"

# ── /v1/chats ───────────────────────────────────────────────────────────────
rule "GET /v1/chats (accountIDs allowlist, no limit — as BeeperClient sends it)"
api /v1/chats "$QUERY_ACCOUNTS"
CHATS="$RESP"
say "  HTTP $HTTP_STATUS"
[ "$HTTP_STATUS" = "200" ] || exit 1
say "  hasMore=$(printf '%s' "$CHATS" | jq -r '.hasMore') oldestCursor=$(printf '%s' "$CHATS" | jq -r 'if .oldestCursor == null then "null" else "present" end') newestCursor=$(printf '%s' "$CHATS" | jq -r 'if .newestCursor == null then "null" else "present" end')"
CHAT_ITEMS="$(printf '%s' "$CHATS" | jq '.items // []')"
presence "$CHAT_ITEMS" "$CHAT_FIELDS"
say "  fields §3/§4 will need:"
presence "$CHAT_ITEMS" "$CHAT_LATER_FIELDS"
extras "$CHAT_ITEMS" "$CHAT_KNOWN"
LEAKED="$(printf '%s' "$CHAT_ITEMS" | jq '[.[] | select(.accountID|ascii_downcase|contains("imessage"))] | length')"
if [ "$LEAKED" = "0" ]; then
  say "  ✓ no iMessage chat came back through the allowlist"
else
  say "  ! $LEAKED iMessage chat(s) returned despite accountIDs — duplicate threads. File this."
fi
say "  chat shape (values replaced by their type):"
shape_of "$CHAT_ITEMS"

# ── /v1/chats/{id}/messages ─────────────────────────────────────────────────
rule "GET /v1/chats/{chatID}/messages (no direction — SDK behaviour)"
CHAT_ID="$(printf '%s' "$CHAT_ITEMS" | jq -r '.[0].id // empty')"
if [ -z "$CHAT_ID" ]; then
  say "  skipped — no chats returned"
else
  api "/v1/chats/$(jq -rn --arg v "$CHAT_ID" '$v|@uri')/messages"
  MSGS="$RESP"
  say "  HTTP $HTTP_STATUS"
  MSG_ITEMS="$(printf '%s' "$MSGS" | jq '.items // []')"
  say "  hasMore=$(printf '%s' "$MSGS" | jq -r '.hasMore // false')"
  presence "$MSG_ITEMS" "$MESSAGE_FIELDS"
  extras "$MSG_ITEMS" "$MESSAGE_KNOWN"
  say "  type distribution (mapper drops REACTION/NOTICE/isDeleted/isHidden):"
  printf '%s' "$MSG_ITEMS" | jq -r 'group_by(.type)[] | "  · \(.[0].type // "null"): \(length)"' | tee -a "$REPORT"
  say "  dropped by the mapper: $(printf '%s' "$MSG_ITEMS" | jq '[.[] | select(.type == "REACTION" or .type == "NOTICE" or .isDeleted == true or .isHidden == true)] | length')"
  say "  text looks like HTML in: $(printf '%s' "$MSG_ITEMS" | jq '[.[] | select((.text // "") | test("<[a-zA-Z/]"))] | length') of $(printf '%s' "$MSG_ITEMS" | jq 'length')"
  say "  sortKey non-null: $(printf '%s' "$MSG_ITEMS" | jq '[.[] | select(.sortKey != null)] | length') (this is the cursor — 0 breaks paging)"
  say "  message shape:"
  shape_of "$MSG_ITEMS"

  # Second page, exactly the way BeeperClient advances: resend oldestCursor.
  CURSOR="$(printf '%s' "$MSGS" | jq -r '.oldestCursor // empty')"
  if [ -n "$CURSOR" ]; then
    api "/v1/chats/$(jq -rn --arg v "$CHAT_ID" '$v|@uri')/messages" \
        "cursor=$(jq -rn --arg v "$CURSOR" '$v|@uri')"
    PAGE2="$RESP"
    say "  page 2 via oldestCursor: HTTP $HTTP_STATUS, $(printf '%s' "$PAGE2" | jq '.items // [] | length') item(s)"
    OVERLAP="$(jq -n --argjson a "$MSG_ITEMS" --argjson b "$(printf '%s' "$PAGE2" | jq '.items // []')" \
      '[$a[].id] as $x | [$b[] | select(.id as $i | $x | index($i))] | length')"
    say "  overlap with page 1: $OVERLAP (non-zero means we page into the future or repeat)"
  fi
fi

# ── searches ────────────────────────────────────────────────────────────────
rule "GET /v1/chats/search"
api /v1/chats/search "query=a&limit=3&$QUERY_ACCOUNTS"
SC="$RESP"
say "  HTTP $HTTP_STATUS, $(printf '%s' "$SC" | jq '.items // [] | length') item(s)"
if [ "$HTTP_STATUS" = "200" ]; then extras "$(printf '%s' "$SC" | jq '.items // []')" "$CHAT_KNOWN"; fi

rule "GET /v1/messages/search"
api /v1/messages/search "query=a&limit=3&$QUERY_ACCOUNTS"
SM="$RESP"
say "  HTTP $HTTP_STATUS, $(printf '%s' "$SM" | jq '.items // [] | length') item(s)"
if [ "$HTTP_STATUS" = "200" ]; then extras "$(printf '%s' "$SM" | jq '.items // []')" "$MESSAGE_KNOWN"; fi

rule "GET /v1/accounts/{accountID}/contacts"
api "/v1/accounts/$(jq -rn --arg v "$FIRST_ACCOUNT" '$v|@uri')/contacts" "query=a&limit=3"
CT="$RESP"
say "  HTTP $HTTP_STATUS, $(printf '%s' "$CT" | jq '.items // [] | length') item(s)"
if [ "$HTTP_STATUS" = "200" ]; then
  presence "$(printf '%s' "$CT" | jq '.items // []')" "$USER_FIELDS"
  extras "$(printf '%s' "$CT" | jq '.items // []')" "$USER_KNOWN"
fi

rule "Result"
say "  Validated app.version: $APP_VERSION"
say "  Report: $REPORT"
say ""
say "  The report carries field names, JSON types and counts only — no message"
say "  bodies, names, handles or IDs. Safe to paste."
