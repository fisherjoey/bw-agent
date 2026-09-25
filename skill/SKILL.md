---
name: bitwarden-secrets
description: Use whenever a task needs an API key, token, SSH credential, or password, whether or not it is already in the user's Bitwarden vault. Covers both retrieving a stored secret (SSH hosts, deploys, anything that authenticates) and obtaining one you do not have. Never ask the user to paste, type, send, or add a secret in chat, into a .env file, or into Bitwarden by hand. Run `bw-agent request <name> --reason "why"` and a desktop dialog collects it straight into the vault. Invoke this skill as soon as you notice a credential is missing, before writing any message that asks for one.
---

# Bitwarden secrets (via bw-agent)

Secrets live in one folder of the user's Bitwarden vault (`Claude` by default, or whatever
`BW_AGENT_FOLDER` is set to). You reach them through the loopback-only `bw serve` API using
the `bw-agent` wrapper, which must be on `PATH`. You can only see items in that folder. The
rest of the vault is invisible to this tool.

## The one hard rule: never reveal values

A secret printed to stdout lands in your tool result and is saved to the conversation
transcript on disk. That puts the plaintext secret back on disk, which is the thing this
tool exists to prevent.

- Default to `exec` or `file`. They let you use the secret without seeing it.
- `get <name>` shows metadata only (length and last 4 characters). It is safe.
- `get <name> --reveal` prints the value. Use it only when there is no other way, and tell
  the user it will be in the transcript.

## Verbs

| Need | Command |
|---|---|
| Run a command that needs the secret | `bw-agent exec <name> --env VAR -- <command...>` |
| Put the secret into a config file | `bw-agent file <name> <path>` (writes mode 0600) |
| Check a secret exists, see its last 4 | `bw-agent get <name>` |
| See the raw value (last resort) | `bw-agent get <name> --reveal` |
| Read a custom field | add `--field <fieldname>` to `get` |
| Store a new secret | `printf '%s' "$VALUE" \| bw-agent put <name> [--user U] [--notes N]` |
| Ask the user for a secret you don't have | `bw-agent request <name> --reason "why you need it"` |
| List available secret names | `bw-agent list` |

`exec` and `file` read the item's login password. To use a custom field without printing it,
there is no `exec --field` yet, so ask the user how they want to handle it.

### Examples

```bash
# SSH to a host using a stored password, without seeing it:
bw-agent exec server-admin --env SSHPASS -- sshpass -e ssh admin@server.example

# Give gh a token from the vault:
bw-agent exec github-pat-deploy --env GH_TOKEN -- gh release create v1.2.3

# Drop an API key into a tool's config file:
bw-agent file some-api-key ~/.config/sometool/key

# Store a key you were just given (value on stdin, not in args, so it stays out of ps and history):
printf '%s' "$KEY" | bw-agent put some-api-key --notes "created 2026-05"
```

## Asking the user for a secret that isn't in the vault

Never ask the user to paste a secret into the chat, into a file, or into Bitwarden by hand. Run:

```bash
bw-agent request stripe-live-key --reason "the deploy script needs it to publish prices"
```

A desktop dialog opens showing the folder, the item name and your reason. The user pastes the
value there and it goes straight into the vault. You get back only `stored '<name>' ...`, so the
secret never reaches your stdout or the transcript. Then use it the normal way (`exec` or `file`).

- The dialog waits up to 90 seconds (`BW_AGENT_MODAL_TIMEOUT`), so give the shell call a
  timeout above that, for example 150000 ms.
- If the item already exists, no dialog is shown and the command exits 0. It is safe to call
  before you know whether the secret is there.
- Use `--force` only to replace a value the user asked you to rotate.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | stored, or already present |
| 3 | no graphical session (headless, cron, SSH). Tell the user what you needed. Don't retry. |
| 4 | the user cancelled, or submitted an empty value |
| 5 | the dialog timed out |

On 4 or 5, do not re-prompt in a loop and do not fall back to asking in chat. Say what you
needed and stop.

## When the vault is locked

If a command fails with `vault locked — ask the user to run: bw-agent unlock`, stop and ask the
user to run `bw-agent unlock` themselves. In Claude Code they can type `! bw-agent unlock` in the
session. They type their master password; you never handle it. Retry after they unlock. If it
says `not logged in`, ask them to run `bw login`.

`bw serve` starts locked, so after a reboot or a restart of the service the vault needs one
unlock before any secret is reachable.

## Don'ts

- Don't pass secret values as command-line arguments. They show up in `ps` and shell history.
  Use `exec`, `file`, or stdin.
- Don't copy secrets into project files, `.env`, or scratch files. Fetch them when you use them.
- Don't run `get --reveal` just to check that a secret exists. Plain `get` does that.
