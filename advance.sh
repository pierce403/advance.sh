#!/usr/bin/env bash
# advance.sh — make one AI-powered improvement to your repo and open a PR.
#
# Requirements:
#   - git (with a remote named "origin")
#   - curl
#   - An OpenAI-compatible API key in $OPENAI_API_KEY
#     (or set ADVANCE_API_URL / ADVANCE_MODEL to use a different provider)
#
# Usage:
#   chmod +x advance.sh
#   OPENAI_API_KEY=sk-... ./advance.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables
# ---------------------------------------------------------------------------
API_URL="${ADVANCE_API_URL:-https://api.openai.com/v1/chat/completions}"
MODEL="${ADVANCE_MODEL:-gpt-4o}"
MAX_TOKENS="${ADVANCE_MAX_TOKENS:-4096}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '\033[1;34m[advance]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[advance] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found in PATH."
  done
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require git curl

[[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY is not set."

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository."

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Gather repo context
# ---------------------------------------------------------------------------
log "Gathering repository context..."

# File tree (exclude .git and common noise)
FILE_TREE="$(git ls-files | head -200)"

# Recent git log
GIT_LOG="$(git --no-pager log --oneline -10 2>/dev/null || echo '(no commits yet)')"

# Sample file contents (first 100 lines of up to 5 tracked files)
ADVANCE_EXCLUDE_EXTENSIONS="${ADVANCE_EXCLUDE_EXTENSIONS:-png|jpg|gif|ico|svg|woff|woff2|ttf|eot|pdf|zip|tar|gz}"

FILE_SAMPLES=""
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  FILE_SAMPLES+="### $f ###\n$(head -100 "$f")\n\n"
done < <(git ls-files | grep -v -E "\.(${ADVANCE_EXCLUDE_EXTENSIONS})\$" | head -5)

# ---------------------------------------------------------------------------
# Ask the LLM for one concrete improvement
# ---------------------------------------------------------------------------
log "Asking ${MODEL} for one improvement..."

SYSTEM_PROMPT='You are an expert software engineer contributing to an open-source project.
Your task is to suggest ONE small, concrete, self-contained improvement to the repository.
The improvement must be:
  - Specific (a real code, documentation, or configuration change)
  - Completable in a single commit
  - Described as a unified diff (--- a/file ... +++ b/file) OR as a new file with its full contents
Respond with ONLY a JSON object in this exact shape (no markdown fences):
{
  "branch": "<short-slug-for-pr-branch>",
  "commit_message": "<conventional-commit style message>",
  "pr_title": "<concise PR title>",
  "pr_body": "<one paragraph explaining the change>",
  "changes": [
    {
      "action": "create" | "modify" | "delete",
      "path": "<relative file path>",
      "content": "<full new file content, or null for delete>"
    }
  ]
}'

USER_PROMPT="Repository file tree:\n${FILE_TREE}\n\nRecent commits:\n${GIT_LOG}\n\nFile samples:\n${FILE_SAMPLES}\n\nPlease suggest one improvement."

# Build the JSON payload safely with Python (avoids shell quoting nightmares)
PAYLOAD="$(python3 -c "
import json, sys
payload = {
    'model': '${MODEL}',
    'max_tokens': ${MAX_TOKENS},
    'messages': [
        {'role': 'system', 'content': sys.argv[1]},
        {'role': 'user',   'content': sys.argv[2]},
    ]
}
print(json.dumps(payload))
" "$SYSTEM_PROMPT" "$(printf '%b' "$USER_PROMPT")")"

RESPONSE="$(curl -fsSL \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$API_URL")"

# Extract the assistant message content
LLM_OUTPUT="$(printf '%s' "$RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data['choices'][0]['message']['content'])
")"

# ---------------------------------------------------------------------------
# Parse the LLM response
# ---------------------------------------------------------------------------
log "Parsing LLM response..."

BRANCH="$(printf '%s' "$LLM_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['branch'])")"
COMMIT_MSG="$(printf '%s' "$LLM_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['commit_message'])")"
PR_TITLE="$(printf '%s' "$LLM_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['pr_title'])")"
PR_BODY="$(printf '%s' "$LLM_OUTPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['pr_body'])")"

# Sanitise branch name
BRANCH="advance/$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | cut -c1-60)"

# ---------------------------------------------------------------------------
# Apply the changes
# ---------------------------------------------------------------------------
log "Creating branch '${BRANCH}'..."
git checkout -b "$BRANCH"

log "Applying file changes..."
python3 - "$LLM_OUTPUT" <<'PYEOF'
import json, os, sys

data = json.loads(sys.argv[1])
for change in data.get("changes", []):
    action  = change["action"]
    path    = change["path"]
    content = change.get("content")

    # Safety: never write outside the repo
    abs_path = os.path.realpath(path)
    cwd      = os.path.realpath(".")
    if not abs_path.startswith(cwd + os.sep):
        print(f"  [skip] path '{path}' is outside the repository root", file=sys.stderr)
        continue

    if action in ("create", "modify"):
        os.makedirs(os.path.dirname(abs_path) or ".", exist_ok=True)
        with open(abs_path, "w") as fh:
            fh.write(content or "")
        print(f"  {action}: {path}", file=sys.stderr)
    elif action == "delete":
        if os.path.exists(abs_path):
            os.remove(abs_path)
            print(f"  delete: {path}", file=sys.stderr)
PYEOF

# ---------------------------------------------------------------------------
# Commit
# ---------------------------------------------------------------------------
git add -A
git diff --cached --quiet && die "No changes were made by the LLM — nothing to commit."

git commit -m "$COMMIT_MSG"
log "Committed: ${COMMIT_MSG}"

# ---------------------------------------------------------------------------
# Push & open PR
# ---------------------------------------------------------------------------
log "Pushing branch to origin..."
git push -u origin "$BRANCH"

# Detect the default branch for the PR base
DEFAULT_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"

# Try gh CLI first, fall back to printing a URL
if command -v gh >/dev/null 2>&1; then
  log "Opening PR with 'gh'..."
  gh pr create \
    --title "$PR_TITLE" \
    --body  "$PR_BODY" \
    --base  "$DEFAULT_BRANCH" \
    --head  "$BRANCH"
else
  REMOTE_URL="$(git remote get-url origin)"
  # Convert SSH URL to HTTPS if needed
  REMOTE_URL="$(printf '%s' "$REMOTE_URL" | sed 's|git@github.com:|https://github.com/|; s|\.git$||')"
  ENCODED_TITLE="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PR_TITLE")"
  ENCODED_BODY="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PR_BODY")"
  PR_URL="${REMOTE_URL}/compare/${DEFAULT_BRANCH}...${BRANCH}?quick_pull=1&title=${ENCODED_TITLE}&body=${ENCODED_BODY}"
  log "Open this URL in your browser to create the PR:"
  printf '%s\n' "$PR_URL"
fi

log "Done! 🚀"
