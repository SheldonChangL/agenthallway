# install.sh

The one-line install for macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/SheldonChangL/agenthub/main/install.sh | sh
```

It downloads one release asset, **verifies it against that release's own
`SHA256SUMS` before anything is unpacked**, puts it somewhere this account can
already write, and registers the background node with launchd or
`systemd --user`. It never runs `sudo` and never asks for a password.

Piping a script from the internet into a shell is a thing worth being uneasy
about. Read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/SheldonChangL/agenthub/main/install.sh | less
```

`--dry-run` is the other half of that: it prints every command it would run, in
order, and runs none of them.

Through a pipe the shell reads the script on standard input, so flags go after
`sh -s --`:

```sh
curl -fsSL .../install.sh | sh -s -- --no-service
```

Everything with an effect is inside the script's `main()`, and `main "$@"` is
the last line of the file. A connection that drops halfway leaves the shell
with function definitions and no call: half a download runs nothing, rather
than half an install that exits 0.

## Two names: Agent Hallway, and AgentHub before it

Agent Hallway was called AgentHub up to v0.1.11. The script installs both:

- **A tag up to v0.1.11** (`v0.0.*`, `v0.1.*`, with or without the `v`) is
  installed exactly as v0.1.11's script installed it, under the names it was
  released with: `agenthub-desktop.app`, `~/.local/share/agenthub`,
  `agenthub-node`, `agenthub-mcp`, the `agenthub-watch` skill. This is what
  `curl …/main/install.sh | sh` does while the latest release is still v0.1.11.
- **Any later tag** (v0.2.0, a release candidate of it, and the dry run's
  `vX.Y.Z` placeholder) is installed under the current names
  (`agenthallway-desktop.app`, `~/.local/share/agenthallway`,
  `agenthallway-node`, `agenthallway-mcp`, `agenthallway-watch`), after which
  the pre-rename install is retired (see "Upgrading from AgentHub" below).

Without `--version` the latest release decides. With `--from` the file name
decides: `agenthub_*` and `agenthub-desktop_*` are pre-rename, anything else is
current. Once the archive is unpacked or the disk image mounted, its contents
must agree — a tree must hold that era's node binary, an image that era's app —
or the install stops with "the archive name says … but it contains …" before
anything installed is stopped or replaced.

Throughout this page, a path written `agenthallway` is the current name, and
the pre-rename install used `agenthub` in the same place.

## Flags

| Flag | What it does |
|---|---|
| `--version vX.Y.Z` | Install this release instead of the latest. `AGENTHALLWAY_VERSION` in the environment does the same (the pre-rename `AGENTHUB_VERSION` is read when it is not set), which is how a piped invocation passes it. |
| `--cli-only` | Install `ah`, `agenthallway-node` and `agenthallway-mcp` without the desktop app, from `agenthallway_<tag>_<os>_<arch>.tar.gz`. |
| `--no-service` | Do not register the background node. Nothing starts at login; `ah service install` does it later. On an upgrade it also means the pre-rename install is kept, since its registration stays (see below). |
| `--no-open` | Do not open the app at the end (macOS). |
| `--no-modify-path` | Do not add `~/.local/bin` to `PATH` in the shell's startup file; print the `export` line to add instead. |
| `--no-skill` | Do not install the `agenthallway-watch` skill for Claude Code (see "The Claude Code skill" below). With `--uninstall`, or on an upgrade, leave an installed one, under either name, in place. A `--prefix` install skips the skill anyway. |
| `--uninstall` | Remove what the script installed, under either name, instead of installing; see "Uninstall" below. |
| `--purge` | With `--uninstall`, also delete the node's identity, database and log files — only those files; see "Purge" below. |
| `--prefix DIR` | Install under `DIR` instead of `/Applications` and `~/.local`. Symlinks then go to `DIR/bin`, and nothing outside `DIR` is written. Mostly a test hook. |
| `--from FILE` | Install from a local `.dmg` or `.tar.gz` instead of downloading. A `SHA256SUMS` beside the file is still checked; if there is none, the script prints a `warning:` line on stderr and continues, because you named the file yourself. |
| `--dry-run` | Print every command instead of running it. |
| `-h`, `--help` | The flag list. |

`AGENTHALLWAY_HOME` overrides where the Linux and `--cli-only` trees are
unpacked. The pre-rename `AGENTHUB_HOME` is read when it is not set; a tree it
names is the pre-rename tree and the current one at once, so an upgrade replaces
it in place and never retires it.

### Directories it refuses

An upgrade replaces what it installed (the app bundle and the `share/…` tree,
never the prefix itself), and replacing means `rm -rf`. So both `--prefix` and
`AGENTHALLWAY_HOME` (or `AGENTHUB_HOME`) are refused, before anything is
downloaded to it or deleted, when the directory is:

- `/`;
- your home directory, or any directory containing it;
- an existing directory with no install of either name in it — no `ah`, no
  `bin/ah`, no `agenthallway-desktop` or `agenthub-desktop` (binary or `.app`),
  no `share/agenthallway` or `share/agenthub`, and neither the
  `.agenthallway-install` nor the `.agenthub-install` marker this script
  writes into a prefix it created.

A directory that does not exist yet is fine: it is created. `HOME` unset is a
message naming `--prefix`, not an unbound-variable error.

## What it picks

| Machine | Asset (current names; a pre-rename tag has `agenthub` for `agenthallway`) |
|---|---|
| macOS, Apple silicon or Intel | `agenthallway-desktop_<tag>_darwin_universal.dmg` |
| Linux x86\_64, WebKit2GTK 4.1 on the machine (or nothing yet) | `agenthallway-desktop_<tag>_linux_amd64.tar.gz` |
| Linux x86\_64, only WebKit2GTK 4.0 on the machine (Ubuntu 22.04, Debian 12, Mint, Pop!\_OS) | `agenthallway-desktop_<tag>_linux_amd64_webkit40.tar.gz` — same contents, linked against the older ABI; a tag that predates it falls back to the 4.1 archive of the same name family with a warning |
| Linux arm64 | `agenthallway_<tag>_linux_arm64.tar.gz` — there is no arm64 desktop build, and the script says so before it falls back |
| any, with `--cli-only` | `agenthallway_<tag>_<os>_<arch>.tar.gz` |

Without `--version` the tag comes from
`https://api.github.com/repos/SheldonChangL/agenthub/releases/latest`, read with
`sed`; there is no `jq` dependency. The tag is read before any path is decided,
because it decides the names. A release that has no desktop asset for this
platform stops the install with a message naming `--cli-only`, rather than
installing half of something.

## Exactly what it writes

**macOS**

| Path | What |
|---|---|
| `/Applications/agenthallway-desktop.app` | The app, with `ah`, `agenthallway-node` and `agenthallway-mcp` inside `Contents/MacOS` beside the `desktop` executable. `~/Applications/agenthallway-desktop.app` instead when `/Applications` is not writable by this account — never `sudo`. |
| `~/.local/bin/ah` | A symlink to the `ah` inside the app. The directory is created if it does not exist. |
| `~/.zshrc`, or another shell startup file | A blank line, a `# added by the Agent Hallway installer` comment and `export PATH="$HOME/.local/bin:$PATH"`, appended only when `~/.local/bin` is not already on `PATH` and the file does not already carry this comment or the pre-rename one. Which file depends on the shell; see "PATH" below. |
| `~/Library/LaunchAgents/local.agenthallway.node.plist` | Written by `ah service install`, not by this script. |
| `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/agenthallway-watch/` | The Claude Code skill that teaches an agent to use `ah`, copied from the verified archive, with a `.agenthallway-install` marker file inside. Skipped with `--no-skill`, and left alone when something that is not this script's copy is already there. See "The Claude Code skill" below. |
| `~/Library/Application Support/agenthallway/` | The node's own identity and database, created (or moved there from `…/agenthub/`) by the node on its first start — **unless a service is already registered with a `--db`**, which is kept. See "An already-registered service" below. |

**Linux**

| Path | What |
|---|---|
| `~/.local/share/agenthallway/` | The unpacked app directory: `agenthallway-desktop`, `ah`, `agenthallway-node`, `agenthallway-mcp`, `LICENSE`, `README.txt`, and `skills/agenthallway-watch/`. `AGENTHALLWAY_HOME` (or `AGENTHUB_HOME`) moves it. |
| `~/.local/bin/ah`, `~/.local/bin/agenthallway-desktop` | Symlinks into that directory. With `--cli-only`, `ah`, `agenthallway-node` and `agenthallway-mcp` instead. |
| `${XDG_DATA_HOME:-~/.local/share}/applications/agenthallway.desktop` | The applications-menu entry (`Name=Agent Hallway`, `Exec=` the app in that directory, quoted). Not with `--cli-only`. |
| `~/.bashrc`, or another shell startup file | The same PATH lines as on macOS, under the same condition; see "PATH" below. |
| `~/.config/systemd/user/agenthallway-node.service` | Written by `ah service install`, not by this script. |
| `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/agenthallway-watch/` | As on macOS. |
| `${XDG_CONFIG_HOME:-~/.config}/agenthallway/` | The node's own identity and database, as on macOS. |

A pre-rename tag writes the same table with the pre-rename names: the
`agenthub-desktop.app`, `~/.local/share/agenthub/`, `agenthub.desktop`,
`agenthub-watch` with a `.agenthub-install` marker, the
`# added by the AgentHub installer` comment, and `ah service install` from that
release writes `local.agenthub.node` / `agenthub-node.service`.

Plus a temporary directory under `$TMPDIR`, removed on exit by a trap, including
when the install fails or is interrupted. Nothing else is written. In
particular nothing is written to `/usr/local`, `/opt`, `/etc`, or any systemd
path outside this user's own, and no MCP configuration is ever written (see
"Upgrading from AgentHub").

## Upgrading from AgentHub (v0.1.x)

Installing v0.2.0 or later on a machine with a pre-rename install runs, in
this order:

1. Install and verify as above, under the current names. On macOS, a running
   pre-rename `agenthub-desktop` is asked to quit first, the same way an
   upgrade asks its own app (see below): a pre-rename window left running could
   start a pre-rename node of its own while the new node moves its files. On
   Linux the pre-rename node is left running, except when `AGENTHUB_HOME` names
   the tree both installs share, whose binaries are about to be replaced.
2. `ah service install` from the new release (unless `--no-service`), carrying
   the `--db` the registered unit names. The status it reads is the pre-rename
   registration's when that is the only one, and `ah service install` itself
   stops and removes the pre-rename registration (`local.agenthub.node`,
   `agenthub-node.service`) before it writes the new one. The node, on its first
   start, moves its own identity and database from `…/agenthub/` to
   `…/agenthallway/` (only its own files; the node id stays the same). **The
   script never moves, copies or rewrites any data, and never rewrites a
   `--db`.**
3. Retire the pre-rename install: the links `~/.local/bin/agenthub-node`,
   `agenthub-mcp` and `agenthub-desktop` that point into it; the
   `agenthub-desktop.app` bundles in both `/Applications` and `~/Applications`
   (each only if it holds `Contents/MacOS/ah` or `desktop`); the
   `~/.local/share/agenthub/` tree (only if it is an unpacked tree, and not when
   it is also the current tree); the `agenthub.desktop` menu entry whose `Exec=`
   launches that tree's app; the `agenthub-watch` skill only when it is a real
   directory holding `.agenthub-install` (never a symlink, never an unmarked
   copy; not with `--no-skill`); on macOS without `--prefix`, the pre-rename
   bundle id's `~/Library/{Caches,WebKit,HTTPStorages}/com.wails.agenthub-desktop`,
   `Preferences/com.wails.agenthub-desktop.plist` and
   `Saved Application State/com.wails.agenthub-desktop.savedState`; with
   `--prefix`, the prefix's `.agenthub-install` marker. A node the pre-rename
   window started on its own is stopped first, by the full path of its binary.

   **All of it is kept** while a pre-rename registration that runs it is still
   in place — with `--no-service`, or when the service could not be read —
   because the old node would then fail at every login, or be restarted by
   launchd after its identity moved away. The script says so, and running
   `ah service install` and then the script again finishes the job.

   Never touched by this step: data directories, log directories, PATH lines
   and the pre-rename fish file (they still put `~/.local/bin` on `PATH`).
4. Warn, read-only, about MCP configurations that still start
   `agenthub-mcp`, which the upgrade removed: `$CLAUDE_CONFIG_DIR/.claude.json`,
   `~/.claude.json` and `${CODEX_HOME:-~/.codex}/config.toml` are searched for
   that name, and each that mentions it is named, with the advice to replace the
   entry with one keyed `agenthallway` whose command is the `agenthallway-mcp`
   this run installed beside `ah` (the warning gives its full path) and whose
   arguments are the old entry's (tools are now `mcp__agenthallway__*`).
   Project `.mcp.json` files are not searched. These
   files are never written: they are the owner's, Claude Code rewrites
   `~/.claude.json` while it runs, and an entry cannot be told from another
   product's by its key. This step also runs under `--dry-run`.
5. The closing lines say `pre-rename install: removed: …`, `kept, because its
   background service is still registered: …`, or `partly removed` with what is
   left (an app another administrator's `/Applications` holds).

The other way round, a pre-rename tag refuses a machine that has moved on: when
the current data directory holds `node.key`, `agenthallway.db` or
`.migrating-from-agenthub`, or a current unit, app bundle or tree is present,
installing v0.1.x would register a node that looks for its identity in
`…/agenthub/` — which the new node has moved — and it would start as a new node.
It stops before anything is replaced and prints the rollback commands. With
`--no-service` it installs the pre-rename layout, registers nothing, and prints
the same commands:

```sh
"<the current ah>" service uninstall          # removes both registrations; data stays
curl -fsSL .../install.sh | sh -s -- --version v0.1.11 --no-service
"$HOME/.local/bin/ah" service install --db "<config>/agenthallway/agenthallway.db"
```

## PATH

macOS puts no `~/.local/bin` on `PATH`, and neither do some Linux setups, so
an install that only linked `ah` there would end with `ah: command not found`.
When that directory is not on `PATH`, the script appends a comment and one
line that adds it to the startup file of the login shell named by `$SHELL`:

| `$SHELL` | File |
|---|---|
| zsh, or unset on macOS | `$ZDOTDIR/.zshrc`, or `~/.zshrc` when `ZDOTDIR` is not set |
| bash on macOS | the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` that exists, else a new `~/.bash_profile`. Terminal opens bash as a login shell, which reads only the first of those, so a new `.bash_profile` beside an existing `.profile` would switch the `.profile` off. |
| bash on Linux | `~/.bashrc` |
| fish | `${XDG_CONFIG_HOME:-~/.config}/fish/conf.d/agenthallway.fish` |
| sh, dash, ash, ksh, mksh, yash; or unset on Linux | `~/.profile` |
| anything else (csh, nu, ...) | none; the `export` line is printed instead |

It writes them once: a later run that finds `# added by the Agent Hallway
installer`, **or the pre-rename `# added by the AgentHub installer`**, in that
file adds nothing — for fish, in either `conf.d/agenthallway.fish` or the
pre-rename `conf.d/agenthub.fish`. So an upgrade from a pre-rename install adds
no second line. New terminals find `ah`; the terminal the install ran in does
not, because a piped script cannot change its parent shell's environment, so
the closing lines print the `export` for it. With `--prefix` or
`--no-modify-path` no file is touched and the script prints that `export` line
instead. A startup file it cannot write — a read-only symlink, as Nix
home-manager makes them — is a warning with the same `export` line, and the
install carries on to register the node.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/SheldonChangL/agenthub/main/install.sh | sh -s -- --uninstall
```

One run removes the current install and a pre-rename one, whichever are there.
In this order, and each only when it is this script's:

1. The background services. Each registered unit — the current
   (`~/Library/LaunchAgents/local.agenthallway.node.plist` or
   `~/.config/systemd/user/agenthallway-node.service`) and the pre-rename
   (`local.agenthub.node.plist` or `agenthub-node.service`) — is ours when it
   starts the node binary of one of the installs this run removes: the current
   app (in either Applications), the current tree, the pre-rename app, or the
   pre-rename tree. There is one registration per user and name whoever made
   it, so a unit that starts some other node — one registered from a source
   checkout's `bin/ah`, or the real install during a `--prefix` run — is left
   running and named. Ours are taken down with this install's own `ah`, never
   an `ah` found on `PATH`: a current `ah service uninstall` removes both
   registrations, so it is used when neither is someone else's; a pre-rename
   `ah` removes only the pre-rename one, after which a current unit of ours is
   taken down directly; with no `ah` left, each unit of ours is taken down
   directly (`launchctl bootout` or `systemctl --user disable --now`, then the
   file). If `ah service uninstall` fails, nothing else is removed, because an
   app deleted under a registered service fails at every login. A unit that
   names a path inside these installs but cannot be read as starting one of
   their nodes stops the uninstall before anything is removed.
2. On macOS, a running app of either name is asked to quit. A node the window
   started on its own, and on Linux a running window, is stopped, matched by
   the full path of each install's binary.
3. The links in `~/.local/bin` (`ah`, and `agenthallway-node`,
   `agenthallway-mcp`, `agenthallway-desktop` and their pre-rename names) —
   only those that point into one of these installs; a link to some other `ah`
   is left and named.
4. The apps: on macOS `agenthallway-desktop.app` and `agenthub-desktop.app`,
   each in both `/Applications` and `~/Applications`, since which one install
   picks can change after it ran (an account made admin); each goes only when
   it holds `Contents/MacOS/ah` or `desktop`. On Linux the trees
   `~/.local/share/agenthallway/` and `~/.local/share/agenthub/` (or
   `AGENTHALLWAY_HOME` / `AGENTHUB_HOME`), each only when `ah` and a node
   binary of either name are at its top level and it is neither `/`, your home,
   nor a directory containing it — a source checkout, which has `bin/ah`, a
   `go.mod` or a `.git`, is left. With `--prefix`, both prefix markers. The
   Linux menu entries go when their `Exec=` launches the matching tree's app.
5. The Claude Code skills: `agenthallway-watch` when it holds
   `.agenthallway-install`, `agenthub-watch` when it holds `.agenthub-install`
   — each only as a real directory with its own name's marker. A symlink or a
   copy of your own is left and named. `--no-skill` leaves both.
6. The PATH lines, under either comment: the comment, the `export` under it and
   the blank line above them, from every startup file in the "PATH" table, and
   both fish files (`agenthallway.fish`, `agenthub.fish`) whole when they carry
   the comment line. The rest of each file is kept as it was, except that a
   file whose last line had no newline gets one. A file that mentions a
   comment only in some other form (a CRLF copy, a commented-out one) is left
   as it is, with a warning; where an exact comment line is there as well, that
   block is the one removed.
7. On macOS, both bundle ids' caches and preferences under `~/Library`
   (`Caches`, `WebKit`, `HTTPStorages`, `Preferences`,
   `Saved Application State`), the ids read from each found bundle's
   `Info.plist`, else `com.wails.agenthallway-desktop` and
   `com.wails.agenthub-desktop`.

It keeps the node's identity and database by default —
`~/Library/Application Support/agenthallway/` on macOS,
`${XDG_CONFIG_HOME:-~/.config}/agenthallway/` on Linux, the pre-rename
`…/agenthub/` for a node that has not started since the rename, or beside the
database the service unit names — and its logs, so installing again brings the
same node back with its pairings. Either way the machines paired with this one
still list it until they revoke it (`ah revoke <node-id>`, or from their app).

With `--prefix`, the run removes that prefix's apps, trees, links and markers.
Outside the prefix it touches only what the prefix install itself wrote there —
on Linux the menu entry, which a `--prefix` install also writes, when its
`Exec=` is the prefix's app — and nothing else: no startup file (a `--prefix`
install never writes one), no `~/Library` caches (they are named by bundle id,
so the real install's are the same ones), no skill, and a service or data only
when they are the prefix's own. `--dry-run` prints every command and removes
nothing; its last line says so. Something whose directory this account cannot
write — an app another administrator put in `/Applications` — is a warning
naming it, and the closing line says what is left.

### Purge

`--uninstall --purge` deletes the node's identity, database and logs as well,
so a reinstall is a new node. It does so only when the node they belong to is
this install's: with a registered unit that is someone else's, or on a
`--prefix` run without a unit of its own, it leaves the data and says so.

**It deletes files, never a directory whole.** On macOS the pre-rename data
directory `~/Library/Application Support/agenthub` is, on the default
case-insensitive disk, also the directory of an unrelated app called AgentHub
(`~/Library/Application Support/AgentHub`), and a database kept in `./data` of
a checkout has neighbours of its own. So it looks in each of: the directory
beside the database the registered unit names, the current default data
directory, and the pre-rename default — and in each removes only these files
(with `rm -f`, never a directory):

- `node.key`, and `.node.key-*` (the temporary file a key is written through);
- `agenthallway.db` and `agenthub.db`, each with `-wal`, `-shm` and `-journal`;
- `.migrating-from-agenthub` (the node's marker while it moves its files);
- the database the unit names, with its `-wal`, `-shm` and `-journal`, in that
  database's own directory.

Then it removes the directory with `rmdir` if that left it empty, and otherwise
leaves it and says which files kept it (`left <dir>: it holds files that are
not Agent Hallway's (…)`). The log directories — `~/Library/Logs/agenthallway`
and `~/Library/Logs/agenthub` on macOS,
`${XDG_STATE_HOME:-~/.local/state}/agenthallway` and `…/agenthub` on Linux —
lose `node.log` only, and the same `rmdir`-if-empty rule.

## The Claude Code skill

An agent on this machine cannot use `ah` if nothing tells it `ah` exists. So
the install also puts the `agenthallway-watch` skill — the repository's
`.claude/skills/agenthallway-watch/` — where Claude Code reads user-level
skills: `$CLAUDE_CONFIG_DIR/skills/agenthallway-watch/`, or
`~/.claude/skills/agenthallway-watch/` when `CLAUDE_CONFIG_DIR` is not set.
Claude Code sessions started after the install load it; sessions already
running do not.

It is never downloaded on its own. It travels inside the release asset — under
`skills/` in each `.tar.gz` and `.zip`, and in a hidden `.skills/` folder beside
the app in the `.dmg`, outside the bundle so its signature is untouched — so the
same `SHA256SUMS` check that covers the binaries covers it.

The copy it installs carries a `.agenthallway-install` marker file (a
pre-rename tag's `agenthub-watch` carries `.agenthub-install`). An upgrade
replaces a directory with that marker; anything else at that path — a symlink
to skills you keep elsewhere, or a copy you made yourself — is left as it is,
and the script says so in one line. A `--prefix` install writes nothing outside
its prefix, so it skips the skill (and a `--prefix` uninstall does not look for
one). A release from before the skill shipped (say, with `--version` pointing
at an older tag) installs everything else and prints a `warning:` that no skill
was installed.

## The quarantine flag on macOS

After the app is in place the script runs
`xattr -dr com.apple.quarantine` on it.

That is deliberate, and it is not a way of getting around a security check. The
app is not notarized (issue #66), so the first launch would otherwise be the
"Apple could not verify" dialog and a detour through System Settings → Privacy &
Security. What that dialog is asking is whether the file is really what its
publisher built — and this script has already answered that question, with a
stronger check than the one being skipped: the release's own `SHA256SUMS`,
compared before a single byte was unpacked. A download whose digest did not
match never reaches this line, because the script exits first.

## Upgrades

Re-running the script upgrades in place. The app directory or tree is unlinked
and replaced rather than written into, so a running node keeps the copy it
already has open, and Linux does not fail with "text file busy".

### An already-registered service

`ah service install` replaces an existing registration outright, and the
database path is not remembered anywhere else. A reinstall that did not carry
`--db` forward would write a unit with no `--db`; the node would then open its
default database, and the machine would come back with a new identity, no
pairings and no history — with nothing on screen saying so.

So before it registers anything, the script asks the installed `ah` what is
registered now (`ah --json service status`, whose `service.Arguments` is read
from the unit file itself; from v0.2.0 that is the pre-rename unit's when it is
the only one, marked `Legacy`) and then:

- **a service is registered with a `--db`** — it runs
  `ah service install --db <that same path>` and prints
  `keeping the node's database at <path>`. The unit's node binary *is* replaced
  on purpose: it must point at the binary this run just installed. Any other
  node flag the old unit carried (`--listen`, `--peer-listen`, …) is not
  carried over, and the script names them in a `warning:` line; the node
  remembers its network settings in its own database, so `ah settings set ...`
  and `ah service restart` are the durable way to hold them.
- **no service is registered** — a plain `ah service install`.
- **the status cannot be read** (the command fails, or an older `ah` does not
  answer `--json`) — the service is **not touched at all**. The app is
  installed, the script exits 0, and it prints the exact command to run:
  `ah service install --db <path to the node's database>`. Registering blind is
  the one thing that could lose data, so it is the one thing it will not do.

### On macOS, a running app is asked to quit

Before a bundle is deleted and replaced, the script looks for that bundle's
running app (`pgrep -f "<app>/Contents/MacOS/desktop"`), says so, and sends
`osascript -e 'quit app "<its name>"'` (`agenthallway-desktop`, or
`agenthub-desktop` for a pre-rename bundle being replaced or retired). If it
has not quit within ten seconds the install stops with instructions, rather
than pulling the bundle out from under a live process. osascript asks by name,
so it is only asked when that very bundle is running.

What osascript answers does not decide anything: the app is a Wails app, which
replies to every quit request with "cancel" (AppleScript error -128, "user
canceled") and then quits on its own a moment later, so only `pgrep` says
whether it went. A failing reply is shown only if the ten seconds run out, after
the script's own instructions.

`ah service install` runs again on every upgrade, not only the first time. The
unit records the **absolute path** of the node beside the `ah` that installed
it, so an owner who moves from `~/Applications` to `/Applications` — or from
one `AGENTHALLWAY_HOME` to another — would otherwise be left with a unit
pointing at a path the upgrade just deleted. On Linux the running node is
stopped before its directory is replaced, and the reinstall starts it again.

## Linux runtime

The Linux app links the system WebKit at run time, and the two Linux desktop
archives link different ABIs, so the script decides which one to download
before fetching anything: it reads `ldconfig -p` (trying `ldconfig`,
`/sbin/ldconfig` and `/usr/sbin/ldconfig`; `AGENTHALLWAY_LDCONFIG_PATHS`
overrides the list for tests) and takes the `_webkit40` archive only when
`libwebkit2gtk-4.0.so.37` is present and `libwebkit2gtk-4.1.so.0` is not.
Everything else — 4.1 present, both present, or neither — gets the 4.1 build,
because 4.1 is what every distribution still adding WebKit2GTK ships and so the
one whose runtime can be installed afterwards. When no `ldconfig` answers, the
script says so and takes the 4.1 build too.

After the install, if the chosen archive's WebKit is still not on the library
path, the script warns and prints the package for this distribution — `apt`,
`dnf` or `pacman`, read from `/etc/os-release` (`AGENTHALLWAY_OS_RELEASE`
overrides it for tests). The install still completes; `ah` and the node do not
need GTK, only the window does.

## Tests

`scripts/test-install.sh` runs in CI alongside `shellcheck -s sh install.sh` and
`sh -n install.sh`. Every run of `install.sh` in it goes through one
`sandboxed()` helper: a HOME and `TMPDIR` of its own; both
`AGENTHALLWAY_APPLICATIONS` and `AGENTHUB_APPLICATIONS` pointed into the
suite's directory (a faked `uname` does not fake the disk, and the fallback
chain would otherwise reach the real `/Applications`); every `XDG_*`, `ZDOTDIR`
and inherited `AGENTHALLWAY_*`/`AGENTHUB_*` home and version variable cleared;
`CLAUDE_CONFIG_DIR` and `CODEX_HOME` inside the suite's directory; and a `PATH`
of the case's shims, shims for `launchctl`, `systemctl`, `osascript`, `open`,
`pgrep`, `pkill`, `hdiutil`, `ditto`, `xattr`, `update-desktop-database`,
`schtasks`, `taskkill`, `curl` and `wget`, then the system bin directories only.
The helper refuses to run anything when a `PATH` entry is elsewhere or one of
those tools resolves outside the suite's directory. Every case that removes
something first runs the same command with `--dry-run` and requires every
absolute path in it to be inside the suite's directory. The suite ends with a
tripwire: the real install's app bundles, service units (and their running
pids), trees, links, skills, data and log directories and startup files are
recorded when the suite starts and compared when it ends, however it ends.

It fakes `uname` through a `PATH` shim so both platforms' `--dry-run`
transcripts are checked on one runner, asserts that the right asset is named
for both eras — v0.1.x tags under the pre-rename names, v0.2.0, its release
candidates and the latest under the current ones — that the digest is
compared before the archive is opened, that `--prefix` keeps every path inside
the prefix, and that no command the script would run is a `sudo`. It installs
for real from locally built archives of both eras — with a matching
`SHA256SUMS`, with a corrupted one (refused with nothing created), and named
for one era while holding the other's binaries (refused before anything is
replaced) — and downloads for real from a local stand-in for the release page
to exercise the WebKit 4.0 fallback.

It upgrades a v0.1.11 layout on Linux and on (faked) macOS and checks what is
retired, what is kept (the data directory byte for byte, the startup file, an
owner's own skill), that a pre-rename registration still in place keeps the
old install, and that a running pre-rename app is asked to quit exactly once;
it checks the refusal of a pre-rename tag over moved data, an uninstall of
both installs at once, a purge of a data directory another app shares (its
files and directories survive; ours go, with `rm -f` and `rmdir` only), both
PATH comments, the read-only MCP warning, and the pre-rename environment names.

It also shims `ah` itself, so the three service cases above are asserted on the
transcript: an existing unit must produce `service install --db /some/where.db`,
a failing `ah` must produce the refusal and no `service install` at all, and a
machine with no service must produce a plain one. It truncates the script at
several lengths and requires the truncated copy to run no commands and create
nothing; it points `--prefix` at `/`, at the run's `$HOME`, at the directory
above it and at a directory of someone else's files, and `AGENTHUB_HOME` at
that last one, and requires a refusal with no `rm` in the transcript; and it
shims `mktemp` to
succeed while printing nothing, with `rm` replaced by a recorder, to prove the
cleanup trap never reaches `rm -rf` with an empty path.

The Claude Code skill is checked with `CLAUDE_CONFIG_DIR` pointed into the
suite's own directory, so the developer's `~/.claude` is never written: a fresh
install, an upgrade that replaces the marked copy, a symlink and an unmarked
copy that are both left alone (by install, by an upgrade's retirement and by
`--uninstall`), `--no-skill`, and an archive without the skill that warns and
still installs.
