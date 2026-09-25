# bw-agent

A small bash wrapper that gives an AI coding agent (Claude Code, or anything else with a shell
tool) access to one folder of your Bitwarden vault, without the secret values ending up in the
conversation transcript.

It talks to the Bitwarden CLI's local API (`bw serve`) over loopback. The main ideas:

- It only sees one vault folder. Items outside it can't be listed or read through this tool.
- The default verbs never print a secret. `exec` puts the secret in a command's environment,
  `file` writes it to a 0600 file, and `get` shows only the length and last four characters.
  Printing the value needs an explicit `--reveal`.
- When the agent needs a secret you haven't stored, `request` opens a password dialog on your
  desktop. You paste the value there and it goes into the vault. The agent only learns that it
  was stored.

Agent transcripts are usually saved to disk as plain text, and sometimes synced or shared.
Anything an agent prints to stdout ends up there. This tool keeps secrets off stdout during
normal use.

## Requirements

- Linux with bash 4 or newer
- The [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`), logged in, with `bw serve`
  running on loopback
- `curl`, `jq`, and coreutils `timeout`
- For `request` only: a graphical desktop session and either `kdialog` (checked first) or
  `zenity`

The `request` dialog is the only part that needs a GUI. Agent shells often don't inherit the
desktop environment, so `bw-agent` copies `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`,
`DBUS_SESSION_BUS_ADDRESS` and `XAUTHORITY` from a running `plasmashell`, `kwin_wayland` or
`gnome-shell` process owned by you. On another desktop, set `BW_AGENT_SESSION_PROCS` to the
process name(s) of your shell or compositor (for example `sway` or `Hyprland`), or export
`DISPLAY`/`WAYLAND_DISPLAY` yourself. With no session found, `request` exits 3.

I have only used it on Linux with KDE Plasma. macOS isn't supported: it relies on `/proc`,
`pgrep -x`, kdialog/zenity and GNU `stat`/`timeout`.

## Install

1. Put the script on your `PATH`:

   ```bash
   install -m 0755 bw-agent ~/.local/bin/bw-agent
   ```

2. Run `bw serve` on loopback. There is an example systemd user unit in
   [`contrib/bw-serve.service`](contrib/bw-serve.service):

   ```bash
   bw login                                   # once
   cp contrib/bw-serve.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now bw-serve
   ```

   Check the `ExecStart` path matches `command -v bw`. Keep `--hostname 127.0.0.1`. The API
   has no authentication of its own, so any process that can reach the port can use an
   unlocked vault.

3. Unlock the vault and create the folder:

   ```bash
   bw-agent unlock          # prompts for your master password
   bw-agent ensure-folder
   ```

   `bw serve` starts locked, so you need to unlock again after each reboot or service restart.

### Installing the Claude Code skill

[`skill/SKILL.md`](skill/SKILL.md) is a Claude Code skill that tells the agent how to use
`bw-agent`: prefer `exec` and `file`, use `request` instead of asking for secrets in chat, and
what to do with each exit code. To install it for your user:

```bash
mkdir -p ~/.claude/skills/bitwarden-secrets
cp skill/SKILL.md ~/.claude/skills/bitwarden-secrets/SKILL.md
```

For a single project, copy it to `<project>/.claude/skills/bitwarden-secrets/` instead. Other
agents can use the same file as plain instructions.

## Usage

```text
bw-agent status                                  show vault lock state
bw-agent unlock | lock | sync
bw-agent list                                    list item names in the folder
bw-agent ensure-folder                           create the folder if missing
bw-agent get <name> [--field F]                  metadata only (length + last 4)
bw-agent get <name> [--field F] --reveal         print the value
bw-agent exec <name> [--env VAR] -- cmd...       run cmd with the password in $VAR (default SECRET)
bw-agent file <name> <path>                      write the password to <path>, mode 0600
bw-agent put <name> [--user U] [--notes N]       store a value read from stdin
bw-agent request <name> [--reason R] [--user U] [--notes N] [--force]
                                                 ask the user through a desktop dialog
```

Examples:

```bash
bw-agent exec github-pat --env GH_TOKEN -- gh release create v1.2.3
bw-agent file some-api-key ~/.config/sometool/key
printf '%s' "$VALUE" | bw-agent put some-api-key --notes "rotated monthly"
bw-agent request stripe-key --reason "deploy script publishes prices"
```

`put` and `request` create an item if the name is new and overwrite the password if it
exists. `request` shows no dialog when the item already exists, unless you pass `--force`.

`exec`, `file` and `put` work with the item's login password. Custom fields can only be read
with `get --field`.

### Exit codes for `request`

| Code | Meaning |
|---|---|
| 0 | stored, or already present (no dialog shown) |
| 3 | no graphical session found |
| 4 | cancelled, or an empty value was submitted |
| 5 | the dialog timed out (`BW_AGENT_MODAL_TIMEOUT`, default 90 seconds) |

Other failures (vault locked, API unreachable, item not found) exit 1 with a message on
stderr. Running with no verb prints usage and exits 64.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `BW_AGENT_FOLDER` | `Claude` | The vault folder the tool is scoped to |
| `BW_AGENT_API` | `http://127.0.0.1:8087` | Where `bw serve` listens |
| `BW_AGENT_MODAL_TIMEOUT` | `90` | Seconds the `request` dialog waits |
| `BW_AGENT_SESSION_PROCS` | `plasmashell kwin_wayland gnome-shell` | Processes to copy the desktop session environment from |

The 90-second default is shorter than the 120-second tool-call limit many agent shells use,
so the agent sees a clean exit 5 instead of being killed while the dialog is open.

## Security model

What it helps with:

- Secrets staying out of agent transcripts, terminal scrollback and logs during normal use,
  because the default verbs don't print values.
- Secrets staying out of `ps` output and shell history. Values are sent to `curl` and `jq` on
  stdin, never as command-line arguments.
- Limiting what the agent can casually browse. It only sees the one folder, so the rest of
  your vault isn't listed or read by this tool.
- Stopping an agent from asking you to paste a secret into chat, where it would be saved.

What it doesn't protect against:

- An agent that decides to read a secret can. `get --reveal` is one flag away, and nothing in
  the script stops the agent from passing it. `exec <name> -- env` or
  `bw-agent file <name> /dev/stdout` will print it too. The skill tells the agent not to do
  this, but that is an instruction, not a control. If you need a hard limit, deny those
  patterns in your agent's permission settings (for example Claude Code's `permissions.deny`
  rules), and accept that a determined agent with a general shell
  can still find a way around it.
- The folder scope is enforced by this script, not by Bitwarden. An agent with shell access can
  call the `bw serve` API or `bw` directly and read the whole unlocked vault. The scope keeps
  honest agents tidy. It doesn't hold back one that is actively trying to get out of it.
- Anything running as your user while the vault is unlocked can use the loopback API. `bw serve`
  has no authentication. Lock the vault (`bw-agent lock`) when you're done if that matters to
  you.
- `get` without `--reveal` still prints the length and last four characters.
- Secrets passed with `exec` live in the child process's environment, which other processes
  running as your user can read from `/proc/<pid>/environ`. Files from `file` are mode 0600
  but stay on disk until you delete them.
- The `request` dialog is a plain kdialog or zenity window. Nothing stops another local
  program from drawing a look-alike, so only paste into it when you expected the request.

## Tests

`tests/run.sh` runs the script against a small mock of `bw serve` (`tests/mock_bw_serve.py`).
It needs bash, curl, jq and python3, and doesn't touch a real vault or open any dialog. CI runs
`bash -n`, `shellcheck` and the tests on each push.

```bash
./tests/run.sh
```

The mock covers only the endpoints `bw-agent` calls. It doesn't test the dialog itself or
behaviour against a real Bitwarden server.

## License

MIT. See [LICENSE](LICENSE).
