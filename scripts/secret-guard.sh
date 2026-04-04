#!/usr/bin/env bash
# PreToolUse hook: enforces kernel-level sandbox on Bash commands (macOS Seatbelt)
# and blocks direct reads of registered .env files.
# Exit 0 with JSON = allow (possibly with modified command)
# Exit 2 = deny
set -uo pipefail

REGISTRY="$HOME/.claude/secrets-registry.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_PROFILE="${SCRIPT_DIR}/sandbox.sb"

INPUT=$(</dev/stdin)

PARSED=$(jq -r '[.tool_name // "", .tool_input.command // .tool_input.file_path // ""] | @tsv' <<< "$INPUT" 2>/dev/null)
TOOL_NAME="${PARSED%%	*}"
COMMAND="${PARSED#*	}"

[[ "$TOOL_NAME" == "Bash" || "$TOOL_NAME" == "Read" ]] || exit 0
[[ -n "$COMMAND" ]] || exit 0

deny() {
  echo "DENIED by Blindfold: $1" >&2
  echo "Use secret-exec.sh to run commands that need secrets." >&2
  exit 2
}

# --- .env file blocking (applies to both Bash and Read) ---
# jq filter duplicated from lib.sh:get_all_env_paths -- intentional to avoid sourcing lib.sh on hot path
if [[ -f "$REGISTRY" ]]; then
  ENV_PATHS=$(jq -r '
    [.global.envProfiles | values // empty] +
    [.projects | to_entries[]? | .value.envProfiles | values // empty]
    | unique | .[]
  ' "$REGISTRY" 2>/dev/null)

  if [[ -n "$ENV_PATHS" ]]; then
    while IFS= read -r env_path; do
      [[ -n "$env_path" ]] || continue
      [[ "$TOOL_NAME" == "Read" && "$COMMAND" == "$env_path" ]] && deny "Direct reading of registered .env file blocked."
      [[ "$TOOL_NAME" == "Bash" && "$COMMAND" == *"$env_path"* ]] && deny "Access to registered .env file blocked."
    done <<< "$ENV_PATHS"
  fi
fi

# --- Sandbox wrapping (Bash only) ---
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

# Exempt Blindfold's own scripts -- must match "bash /path/script.sh" or "/path/script.sh"
# followed by a space, end-of-string, or semicolon (not a suffix like script.sh-evil)
is_exempt() {
  local cmd="$1" path="$2"
  [[ "$cmd" == "bash ${path}" || "$cmd" == "bash ${path} "* ]] && return 0
  [[ "$cmd" == "${path}" || "$cmd" == "${path} "* ]] && return 0
  return 1
}

for script in secret-exec.sh secret-store.sh secret-list.sh secret-delete.sh env-register.sh env-keys.sh env-unregister.sh; do
  is_exempt "$COMMAND" "${SCRIPT_DIR}/${script}" && exit 0
done

# On macOS with Seatbelt: wrap the command in sandbox-exec
if [[ "$OSTYPE" == darwin* && -f "$SANDBOX_PROFILE" ]] && command -v sandbox-exec &>/dev/null; then
  ESCAPED_CMD="${COMMAND//\'/\'\\\'\'}"
  WRAPPED="sandbox-exec -f '${SANDBOX_PROFILE}' bash -c '${ESCAPED_CMD}'"

  jq -n --arg cmd "$WRAPPED" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: {
        command: $cmd
      }
    }
  }'
  exit 0
fi

# --- Fallback: string matching for platforms without sandbox ---
if [[ "$OSTYPE" == darwin* ]]; then
  [[ "$COMMAND" == *"find-generic-password"*"-w"* ]] && deny "Keychain password read blocked."
  [[ "$COMMAND" == *"find-generic-password"*"claude-secret"* ]] && deny "Keychain read of managed secret blocked."
  [[ "$COMMAND" == *"dump-keychain"* ]] && deny "Keychain dump blocked."
  [[ "$COMMAND" == *"claude-secrets"*"-w"* ]] && deny "Keychain read blocked."
elif [[ "$OSTYPE" == linux* ]]; then
  [[ "$COMMAND" == *"secret-tool"*"lookup"*"claude-secrets"* ]] && deny "secret-tool lookup blocked."
  [[ "$COMMAND" == *".claude/vault/"*".gpg"* ]] && deny "GPG vault access blocked."
fi

exit 0
