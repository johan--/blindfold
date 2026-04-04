# Blindfold

A Claude Code plugin that keeps your secrets out of the LLM's context window. API keys, tokens, passwords, and `.env` files live in your OS keychain. The LLM only sees placeholder names like `{{GITHUB_TOKEN}}`, never the actual values.

## Why this exists

When you paste an API key into a chat or run a command that echoes a token, the LLM sees it. That value sits in the context window for the rest of the conversation -- it can leak into logs, suggestions, or tool calls.

Blindfold sits between the LLM and your secrets. It works in four parts:

1. A skill (SKILL.md) tells the LLM to never read secret values directly
2. A PreToolUse hook blocks commands that would output secrets before they run (like `security find-generic-password -w`)
3. A wrapper script (`secret-exec.sh`) resolves secrets in a subprocess and strips values from output before the LLM gets it back
4. A PostToolUse hook scans command output for leaked values after the fact, as a safety net

## Installation

Inside Claude Code, run:

```
/plugin marketplace add thesaadmirza/blindfold
/plugin install blindfold@blindfold
```

That's it. The plugin system handles downloading, hooks, and skill registration. The security hooks activate automatically when the plugin is enabled.

`jq` is required (`brew install jq` / `apt install jq`).

After installing, the registry file is created on first use. Just say "store my API key" and Blindfold takes over.

## How it works

### Storing a secret

Tell Claude "store my GitHub token." A native OS dialog pops up -- password field, masked input. You type the value there. It goes straight to your keychain. Over SSH or Remote Control (no GUI), it falls back to a hidden terminal prompt.

Claude never sees the value.

### Using a secret

Claude builds commands with `{{PLACEHOLDER}}` syntax:

```bash
secret-exec.sh 'curl -H "Authorization: Bearer {{GITHUB_TOKEN}}" https://api.github.com/user'
```

The wrapper resolves `{{GITHUB_TOKEN}}` from your keychain, runs the curl, and replaces the actual token with `[REDACTED:GITHUB_TOKEN]` in the output before returning it to Claude.

### Environment profiles

You can register whole `.env` files under a name:

```bash
secret-exec.sh --env staging 'npm start'
```

All variables from `.env.staging` get injected. Every value is redacted from output. Claude sees variable names but never the values themselves.

## Usage

```
> store my gitlab token
# Opens a native password dialog. Type the value there.
# Claude sees: "OK: GITLAB_TOKEN stored securely (scope: global)."

> curl the gitlab API with my token
# Claude runs: secret-exec.sh 'curl -H "PRIVATE-TOKEN: {{GITLAB_TOKEN}}" ...'
# Output shows: PRIVATE-TOKEN: [REDACTED:GITLAB_TOKEN]

> register my staging environment
# Claude runs: env-register.sh staging .env.staging
# Shows variable names only, never values

> use staging env and start the server
# Claude runs: secret-exec.sh --env staging 'npm start'

> what secrets do I have?
# Lists all secrets and env profiles, organized by scope

> delete my gitlab token
# Removes from keychain and registry
```

## Platforms

| Platform | Secret store | Input dialog |
|----------|-------------|--------------|
| macOS | Keychain | osascript / terminal |
| Linux (GUI) | GNOME Keyring / KWallet | zenity / kdialog |
| Linux (headless) | GPG encrypted files | terminal prompt |
| Windows (WSL) | Credential Manager | PowerShell |

Detected automatically based on `uname -s`. Falls back to terminal prompt when no GUI is available.

## Scoping

Secrets can be global (shared across projects) or project-scoped (tied to a specific directory). A `DATABASE_URL` in your API project is separate from `DATABASE_URL` in your frontend project. Project scope is checked first, global is the fallback.

## Files

```
blindfold/
├── .claude-plugin/
│   ├── plugin.json         # Plugin manifest
│   └── marketplace.json    # Marketplace catalog
├── skills/
│   └── blindfold/
│       └── SKILL.md        # LLM instructions
├── hooks/
│   └── hooks.json          # Auto-registered guard + redaction hooks
├── scripts/
│   ├── lib.sh              # Shared functions (backend detection, registry ops)
│   ├── secret-store.sh     # Store via native dialog or terminal prompt
│   ├── secret-list.sh      # List names, never values
│   ├── secret-delete.sh    # Remove from keychain + registry
│   ├── secret-exec.sh      # Resolve, execute, redact
│   ├── env-register.sh     # Register .env profiles
│   ├── env-keys.sh         # Show env variable names only
│   ├── env-unregister.sh   # Remove env profile
│   ├── secret-guard.sh     # PreToolUse hook script
│   └── secret-redact.sh    # PostToolUse hook script
├── LICENSE
└── README.md
```

## Security model

Storage goes through a native OS dialog -- the value travels from your keyboard to the keychain without touching the LLM context. Execution happens in a subprocess, and output is redacted before the LLM reads it. Direct reads of the keychain or registered `.env` files are blocked by a PreToolUse hook. If something still leaks through a different path, the PostToolUse hook catches it.

The registry file (`~/.claude/secrets-registry.json`) stores secret names and env profile file paths. Never values.

## Limitations

- On macOS, `security add-generic-password` passes the value as a CLI argument, briefly visible in `ps` output. The exposure window is very short, but on shared systems, consider storing secrets from your own terminal.
- The GPG fallback on Linux uses symmetric encryption with a passphrase prompt. For better security, install `secret-tool` with GNOME Keyring.
- Output redaction is string-based. Secrets shorter than 4 characters won't be redacted to avoid false positives.
- The PreToolUse hook matches command patterns. Someone could bypass it by obfuscating commands, but the hook prevents the LLM from accidentally reading secrets, not a determined human.
- `.env` parsing handles `KEY=VALUE` and `KEY="VALUE"`. Multi-line values and shell expansions aren't supported.
- If the script is killed with `SIGKILL` (kill -9), temp files containing secrets may persist in `/tmp/`. Under normal termination, the trap cleans them up.

## License

MIT
