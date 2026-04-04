# Blindfold

A Claude Code plugin that keeps your secrets out of the LLM's context window. API keys, tokens, passwords, and `.env` files live in your OS keychain. The LLM only sees placeholder names like `{{GITHUB_TOKEN}}`, never the actual values.

## Why this exists

When you paste an API key into a chat or run a command that echoes a token, the LLM sees it. That value sits in the context window for the rest of the conversation -- it can leak into logs, suggestions, or tool calls.

Blindfold sits between the LLM and your secrets. On macOS, it wraps every Bash command Claude runs in a Seatbelt sandbox (`sandbox-exec`) that denies the `com.apple.SecurityServer` Mach IPC service. This is a kernel-level block. Obfuscating the command doesn't help because the block isn't inspecting the command string.

Four moving parts:

1. A PreToolUse hook intercepts Bash commands and wraps them in the Seatbelt sandbox before execution.
2. `secret-exec.sh` runs outside the sandbox (it needs keychain access), reads secret values, injects them as env vars, then runs the user command inside the sandbox. Output is redacted before Claude reads it back.
3. A skill file (SKILL.md) tells the LLM to use the wrapper for anything needing secrets.
4. A PostToolUse hook scans output for leaked values as a safety net.

On Linux, falls back to string matching. bubblewrap support planned.

## Installation

`jq` is required on all platforms: `brew install jq` (macOS) or `apt install jq` (Linux).

### Claude Code CLI

```
/plugin marketplace add thesaadmirza/blindfold
/plugin install blindfold@blindfold
```

Hooks register automatically. Restart the session after installing.

### Claude Code Desktop App (Mac / Windows)

1. Click the **+** button next to the prompt box
2. Select **Plugins** > **Manage plugins** > **Marketplaces** tab
3. Add `thesaadmirza/blindfold` as a marketplace
4. Go to the **Plugins** tab and install **blindfold**

### VS Code (Claude Code extension)

Type `/plugins` in the Claude Code prompt box, then add the marketplace and install from there. Same steps as the CLI, just through the VS Code plugin dialog.

### JetBrains (Claude Code extension)

Type `/plugin marketplace add thesaadmirza/blindfold` in the Claude Code prompt inside JetBrains, then `/plugin install blindfold@blindfold`.

### Manual install (any environment, no plugin system needed)

If `/plugin` isn't available or you prefer to set things up by hand:

```bash
git clone https://github.com/thesaadmirza/blindfold.git ~/.claude/skills/blindfold
chmod 700 ~/.claude/skills/blindfold/scripts/*.sh
```

The skill auto-discovers from `~/.claude/skills/`. For the security hooks (guard + redaction), add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-guard.sh", "timeout": 5}]
      },
      {
        "matcher": "Read",
        "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-guard.sh", "timeout": 5}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-redact.sh", "timeout": 10}]
      }
    ]
  }
}
```

Merge with your existing `settings.json` if you have one (don't replace the whole file). Restart Claude Code after adding hooks.

### After installing

The registry file is created on first use. Just say "store my API key" and Blindfold takes over.

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
│   ├── sandbox.sb          # macOS Seatbelt profile (denies keychain Mach IPC)
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

On macOS, every Bash command Claude runs goes through a Seatbelt sandbox that blocks `com.apple.SecurityServer` at the kernel level. The sandbox denies the Mach IPC call that all keychain access goes through. Doesn't matter if the command is a direct `security` call, a Python subprocess, a base64-decoded script, or a temp file. The block is below the shell.

`secret-exec.sh` is the only way to reach secrets. It runs outside the sandbox, reads from the keychain, sets env vars, then runs the actual command inside the sandbox. Output gets redacted before Claude sees it.

Storing a secret goes through a native OS dialog on your machine. The value goes from your keyboard to the keychain. Claude sees "OK: stored." The registry file only has secret names and env profile paths. No values.

On Linux, the guard hook falls back to string matching since Seatbelt is macOS only. bubblewrap support is planned.

## Limitations

- On macOS, enforcement is kernel-level via Seatbelt. On Linux, it falls back to string matching, which can be bypassed by obfuscating commands. bubblewrap support is planned.
- `security add-generic-password` on macOS passes the value as a CLI argument, briefly visible in `ps`. Short exposure window, but on shared systems you may want to store secrets from your own terminal.
- The GPG fallback on Linux uses symmetric encryption with a passphrase prompt. `secret-tool` with GNOME Keyring is more secure if available.
- Output redaction is string-based. Secrets shorter than 4 characters won't be redacted (too many false positives).
- `.env` parsing handles `KEY=VALUE` and `KEY="VALUE"`. Multi-line values and shell expansions aren't supported.
- If the process is killed with SIGKILL, temp files with secrets may persist in `/tmp/`. Normal termination cleans them up.

## License

MIT
