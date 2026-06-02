#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/Users/michaeltorbert/.local/bin"

REPO="michaeltorbert/spaces-manager"
BOT_LOGIN="claude-bot-mt[bot]"
MODEL="${MODEL:-claude-opus-4-6}"
EFFORT="${EFFORT:-max}"
DRY_RUN="${DRY_RUN:-0}"
MAX_DIFF_CHARS="${MAX_DIFF_CHARS:-120000}"
CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-600}"
GITHUB_APP_CURL="${GITHUB_APP_CURL:-/opt/homebrew/bin/github-app-curl}"
CLAUDE_BIN="${CLAUDE_BIN:-/Users/michaeltorbert/.local/bin/claude}"
CLAUDE_TOKEN_FILE="${CLAUDE_TOKEN_FILE:-/Users/michaeltorbert/.config/claude/automation-oauth-token}"
CLAUDE_HOME="${CLAUDE_HOME:-/private/tmp/claude-pr-review-home}"
CLAUDE_CONFIG_HOME="${CLAUDE_CONFIG_HOME:-$CLAUDE_HOME/.config}"

timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  print -r -- "[$(timestamp)] $*"
}

prompt_file=""

cleanup_prompt_file() {
  if [ -n "$prompt_file" ]; then
    /bin/rm -f "$prompt_file"
  fi
}

trap cleanup_prompt_file EXIT

usage() {
  cat <<'EOF'
Usage: scripts/claude-pr-review.sh [--dry-run] <pr-number-or-url>

Asks Claude to review a SpacesManager pull request, posts the formal review
through the Claude GitHub App profile, then posts and verifies a top-level
summary comment linking to that review.

Environment:
  DRY_RUN=1                    Generate Claude review JSON without posting.
  MODEL=claude-opus-4-6         Claude model passed to claude-scheduled.
  EFFORT=max                    Claude effort passed to claude-scheduled.
  CLAUDE_TIMEOUT_SECONDS=600    Hard timeout for Claude generation.
  MAX_DIFF_CHARS=120000         Diff truncation limit for Claude prompt.
  CLAUDE_BIN=...                Claude executable path.
  CLAUDE_HOME=...               Writable HOME for Claude runtime state.
  CLAUDE_TOKEN_FILE=...         OAuth token file used for Claude automation.
  GITHUB_APP_CURL=...           github-app-curl executable path.
EOF
}

trim() {
  /usr/bin/perl -0pe 's/\A\s+//; s/\s+\z//'
}

json_string_field() {
  local field="$1"
  /usr/bin/jq -er --arg field "$field" '.[$field] | strings'
}

parse_pr_number() {
  local raw="$1"
  local parsed=""

  if [[ "$raw" =~ '^[0-9]+$' ]]; then
    parsed="$raw"
  else
    parsed="$(
      print -r -- "$raw" |
        /usr/bin/sed -nE 's#^https://github.com/michaeltorbert/spaces-manager/pull/([0-9]+).*$#\1#p'
    )"
  fi

  if [ -z "$parsed" ]; then
    print -r -- "Expected a PR number or https://github.com/michaeltorbert/spaces-manager/pull/<number> URL" >&2
    exit 2
  fi

  print -r -- "$parsed"
}

verify_workspace_repo() {
  local remote_url repo_from_remote
  remote_url="$(/opt/homebrew/bin/git remote get-url origin 2>/dev/null || true)"
  repo_from_remote="$(
    print -r -- "$remote_url" |
      /usr/bin/sed -E \
        -e 's#^git@github.com:##' \
        -e 's#^ssh://git@github.com/##' \
        -e 's#^https://github.com/##' \
        -e 's#\.git$##'
  )"

  if [ "$repo_from_remote" != "$REPO" ]; then
    print -r -- "Refusing GitHub write: origin is '$remote_url', expected $REPO" >&2
    exit 3
  fi
}

api_get() {
  "$GITHUB_APP_CURL" --profile claude -s "$@"
}

api_post() {
  "$GITHUB_APP_CURL" --profile claude -s -X POST "$@"
}

require_tools() {
  local missing=0

  for tool in /opt/homebrew/bin/git /usr/bin/jq /usr/bin/perl "$GITHUB_APP_CURL" "$CLAUDE_BIN"; do
    if [ ! -x "$tool" ]; then
      print -r -- "Missing executable: $tool" >&2
      missing=1
    fi
  done

  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -r "$CLAUDE_TOKEN_FILE" ]; then
    print -r -- "Missing readable Claude token file: $CLAUDE_TOKEN_FILE" >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    exit 4
  fi
}

claude_oauth_token() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    print -r -- "$CLAUDE_CODE_OAUTH_TOKEN"
  else
    /usr/bin/tr -d '\r\n' < "$CLAUDE_TOKEN_FILE"
  fi
}

format_actor_items() {
  local empty_label="$1"
  local jq_filter="$2"
  /usr/bin/jq -r --arg empty_label "$empty_label" "$jq_filter"
}

extract_claude_review_json() {
  local claude_json="$1"
  local result_text review_json

  result_text="$(
    print -r -- "$claude_json" |
      /usr/bin/jq -r 'if type == "object" and has("result") then .result else . end' 2>/dev/null ||
      print -r -- "$claude_json"
  )"

  review_json="$(
    print -r -- "$result_text" |
      /usr/bin/perl -0pe 's/\A\s*```json\s*//i; s/\A\s*```\s*//; s/\s*```\s*\z//; s/\A\s+//; s/\s+\z//'
  )"

  if ! print -r -- "$review_json" | /usr/bin/jq -e '
    type == "object"
    and (.event | type == "string")
    and (.body | type == "string" and length > 0)
    and ((.top_level_summary // "") | type == "string")
  ' >/dev/null; then
    print -r -- "Claude did not return the expected review JSON." >&2
    print -r -- "$result_text" >&2
    exit 5
  fi

  print -r -- "$review_json"
}

PR_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -n "$PR_ARG" ]; then
        usage >&2
        exit 2
      fi
      PR_ARG="$1"
      ;;
  esac
  shift
done

if [ -z "$PR_ARG" ]; then
  usage >&2
  exit 2
fi

require_tools
verify_workspace_repo

PR_NUMBER="$(parse_pr_number "$PR_ARG")"
API="https://api.github.com/repos/$REPO"

log "fetching live PR #$PR_NUMBER from $REPO"
pr_json="$(api_get "$API/pulls/$PR_NUMBER")"

if print -r -- "$pr_json" | /usr/bin/jq -e 'has("message") and (.message == "Not Found")' >/dev/null; then
  print -r -- "PR #$PR_NUMBER was not found in $REPO" >&2
  exit 6
fi

pr_state="$(print -r -- "$pr_json" | /usr/bin/jq -r '.state // empty')"
pr_title="$(print -r -- "$pr_json" | /usr/bin/jq -r '.title // empty')"
pr_body="$(print -r -- "$pr_json" | /usr/bin/jq -r '.body // ""')"
pr_author="$(print -r -- "$pr_json" | /usr/bin/jq -r '.user.login // empty')"
head_ref="$(print -r -- "$pr_json" | /usr/bin/jq -r '.head.ref // empty')"
head_sha="$(print -r -- "$pr_json" | /usr/bin/jq -r '.head.sha // empty')"
base_ref="$(print -r -- "$pr_json" | /usr/bin/jq -r '.base.ref // empty')"

if [ "$pr_state" != "open" ]; then
  print -r -- "Refusing to review PR #$PR_NUMBER because it is '$pr_state', not open." >&2
  exit 7
fi

files_json="$(api_get "$API/pulls/$PR_NUMBER/files?per_page=100")"
reviews_json="$(api_get "$API/pulls/$PR_NUMBER/reviews?per_page=100")"
review_comments_json="$(api_get "$API/pulls/$PR_NUMBER/comments?per_page=100")"
conversation_comments_json="$(api_get "$API/issues/$PR_NUMBER/comments?per_page=100")"
diff_text="$(api_get -H 'Accept: application/vnd.github.v3.diff' "$API/pulls/$PR_NUMBER")"
agent_instructions="$(/usr/bin/sed -n '1,130p' AGENTS.md)"

export MAX_DIFF_CHARS
diff_text="$(
  print -r -- "$diff_text" |
    /usr/bin/perl -0pe 'BEGIN { $max = int($ENV{"MAX_DIFF_CHARS"} || 120000) } if (length($_) > $max) { $_ = substr($_, 0, $max) . "\n[diff truncated at $max characters]\n" }'
)"

files_summary="$(
  print -r -- "$files_json" |
    /usr/bin/jq -r '
      if length == 0 then
        "(no files returned)"
      else
        map("- \(.filename) \(.status) +\(.additions)/-\(.deletions)") | join("\n")
      end
    '
)"

prior_reviews="$(
  print -r -- "$reviews_json" |
    format_actor_items "(no prior reviews)" '
      if length == 0 then
        $empty_label
      else
        map("\(.user.login) \(.state) \(.submitted_at // ""):\n\(.body // "")\n\(.html_url // "")\n---") | join("\n")
      end
    '
)"

prior_review_comments="$(
  print -r -- "$review_comments_json" |
    format_actor_items "(no inline review comments)" '
      if length == 0 then
        $empty_label
      else
        map("\(.user.login) on \(.path):\(.line // .original_line // 0):\n\(.body // "")\n\(.html_url // "")\n---") | join("\n")
      end
    '
)"

prior_conversation_comments="$(
  print -r -- "$conversation_comments_json" |
    format_actor_items "(no top-level PR conversation comments)" '
      if length == 0 then
        $empty_label
      else
        map("\(.user.login) \(.created_at // ""):\n\(.body // "")\n\(.html_url // "")\n---") | join("\n")
      end
    '
)"

prompt_file="$(/usr/bin/mktemp)"
cat > "$prompt_file" <<EOF
You are Claude reviewing pull request #$PR_NUMBER in $REPO.

GitHub data in this prompt is live from the GitHub API. Local agent instructions
come from AGENTS.md in the current workspace. Use only the provided data. Do not
use tools.

Return strict JSON only, with this shape:
{
  "event": "COMMENT" | "REQUEST_CHANGES" | "APPROVE",
  "body": "formal GitHub pull request review body",
  "top_level_summary": "short top-level PR conversation comment summary"
}

Review rules:
- Findings first. Prioritize correctness, regressions, build/release risks, and
  missing verification.
- Use REQUEST_CHANGES only for material issues that should block merge.
- Use APPROVE only if there are no material issues.
- Use COMMENT for non-blocking concerns, uncertainty, or review notes.
- Do not invent files, symbols, tests, or behavior not shown here.
- Keep the body concise but specific enough that Codex can revise from it.
- If there are prior unresolved Claude review comments, account for them.
- If Codex has already addressed a prior issue, say so briefly instead of
  repeating the stale concern.

Agent instructions:
$agent_instructions

PR:
- title: $pr_title
- author: $pr_author
- base: $base_ref
- head: $head_ref
- head sha: $head_sha

PR body:
$pr_body

Changed files:
$files_summary

Prior reviews:
$prior_reviews

Prior inline review comments:
$prior_review_comments

Prior top-level conversation comments:
$prior_conversation_comments

Diff:
$diff_text
EOF

log "asking Claude to review PR #$PR_NUMBER"
claude_token="$(claude_oauth_token)"
if [ -z "$claude_token" ]; then
  print -r -- "Claude OAuth token is empty." >&2
  exit 8
fi

/bin/mkdir -p "$CLAUDE_HOME" "$CLAUDE_CONFIG_HOME"

if ! claude_json="$(
  CLAUDE_TIMEOUT_SECONDS="$CLAUDE_TIMEOUT_SECONDS" \
    HOME="$CLAUDE_HOME" \
    XDG_CONFIG_HOME="$CLAUDE_CONFIG_HOME" \
    CLAUDE_CODE_OAUTH_TOKEN="$claude_token" \
    /usr/bin/perl -e 'alarm int($ENV{"CLAUDE_TIMEOUT_SECONDS"} || 600); exec @ARGV' \
    "$CLAUDE_BIN" --no-session-persistence -p \
      --tools "" \
      --model "$MODEL" \
      --effort "$EFFORT" \
      --output-format json < "$prompt_file"
)"; then
  print -r -- "Claude review generation failed or timed out." >&2
  exit 8
fi
/bin/rm -f "$prompt_file"
prompt_file=""

review_json="$(extract_claude_review_json "$claude_json")"
event="$(
  print -r -- "$review_json" |
    json_string_field event |
    /usr/bin/tr '[:lower:]' '[:upper:]'
)"
body="$(print -r -- "$review_json" | json_string_field body | trim)"
top_level_summary="$(
  print -r -- "$review_json" |
    /usr/bin/jq -r '.top_level_summary // ""' |
    trim
)"

case "$event" in
  COMMENT|REQUEST_CHANGES|APPROVE)
    ;;
  *)
    print -r -- "Claude returned unsupported review event: $event" >&2
    exit 9
    ;;
esac

if [ -z "$top_level_summary" ]; then
  case "$event" in
    APPROVE)
      top_level_summary="Claude review found no material issues."
      ;;
    REQUEST_CHANGES)
      top_level_summary="Claude review found material issues that should be addressed before merge."
      ;;
    *)
      top_level_summary="Claude review completed with non-blocking notes."
      ;;
  esac
fi

if [ "$DRY_RUN" = "1" ]; then
  log "dry run; not posting GitHub review"
  print -r -- "$review_json" | /usr/bin/jq .
  exit 0
fi

review_payload="$(
  /usr/bin/jq -nc \
    --arg event "$event" \
    --arg body "$body" \
    '{event:$event, body:$body}'
)"

log "posting formal Claude review to PR #$PR_NUMBER"
review_response="$(api_post "$API/pulls/$PR_NUMBER/reviews" -d "$review_payload")"
review_id="$(print -r -- "$review_response" | /usr/bin/jq -r '.id // empty')"
review_url="$(print -r -- "$review_response" | /usr/bin/jq -r '.html_url // empty')"
review_actor="$(print -r -- "$review_response" | /usr/bin/jq -r '.user.login // empty')"

if [ -z "$review_id" ] || [ -z "$review_url" ]; then
  print -r -- "GitHub review post failed:" >&2
  print -r -- "$review_response" >&2
  exit 10
fi

if [ "$review_actor" != "$BOT_LOGIN" ]; then
  print -r -- "Review posted as '$review_actor', expected '$BOT_LOGIN'." >&2
  exit 11
fi

top_level_body="$top_level_summary

Formal Claude review: $review_url"
comment_payload="$(/usr/bin/jq -nc --arg body "$top_level_body" '{body:$body}')"

log "posting top-level Claude review summary to PR #$PR_NUMBER"
comment_response="$(api_post "$API/issues/$PR_NUMBER/comments" -d "$comment_payload")"
comment_url="$(print -r -- "$comment_response" | /usr/bin/jq -r '.html_url // empty')"
comment_actor="$(print -r -- "$comment_response" | /usr/bin/jq -r '.user.login // empty')"

if [ -z "$comment_url" ]; then
  print -r -- "Top-level comment post failed:" >&2
  print -r -- "$comment_response" >&2
  exit 12
fi

if [ "$comment_actor" != "$BOT_LOGIN" ]; then
  print -r -- "Top-level comment posted as '$comment_actor', expected '$BOT_LOGIN'." >&2
  exit 13
fi

verified_review="$(
  api_get "$API/pulls/$PR_NUMBER/reviews?per_page=100" |
    /usr/bin/jq -r --arg id "$review_id" '
      .[] | select((.id | tostring) == $id) | [.user.login, .state, .html_url] | @tsv
    '
)"
verified_comment="$(
  api_get "$API/issues/$PR_NUMBER/comments?per_page=100" |
    /usr/bin/jq -r --arg url "$comment_url" '
      .[] | select(.html_url == $url) | [.user.login, .html_url] | @tsv
    '
)"

if [ -z "$verified_review" ] || [ -z "$verified_comment" ]; then
  print -r -- "GitHub post verification failed." >&2
  print -r -- "review: $verified_review" >&2
  print -r -- "comment: $verified_comment" >&2
  exit 14
fi

log "verified formal review: $verified_review"
log "verified top-level comment: $verified_comment"
