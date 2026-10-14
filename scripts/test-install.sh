#!/usr/bin/env bash
# Exercise install.sh without a network and without touching this machine.
#
# install.sh installs two eras: a tag up to v0.1.11 under the names the
# product had then (AgentHub: agenthub-desktop, agenthub-node, ...), any later
# one under the current names (Agent Hallway: agenthallway-*), after which it
# retires the pre-rename install. The cases built on v0.1.0 below are the
# pre-rename era's coverage; the ones built on v0.2.0 the current era's; the
# upgrade, uninstall and purge cases near the end mix the two.
#
# Every run of install.sh goes through sandboxed(), and the suite ends with a
# tripwire comparing this machine's own install with what it was when the
# suite started (see both below).
#
# Two kinds of check:
#
#   1. --dry-run under a faked `uname`, so the darwin path can be read on Linux
#      and the linux path on a mac. What is asserted is the transcript: the
#      asset name for that platform, that the digest is checked before anything
#      is unpacked, that --prefix keeps every path inside the prefix, and that
#      no command it would run is a sudo.
#   2. A real install from a locally built archive, with a SHA256SUMS that is
#      right and then one that is wrong. The wrong one is the important half:
#      an installer whose verification can be skipped is an installer with no
#      verification, and that is not something a dry run can show.
#
# bash, not sh: this is a test harness and never ships. install.sh itself is
# POSIX sh, which `shellcheck -s sh` and `sh -n` in CI keep true.
set -euo pipefail

repository=$(cd -- "$(dirname -- "$0")/.." && pwd)
installer="$repository/install.sh"
[ -f "$installer" ] || {
	echo "no install.sh at $installer" >&2
	exit 2
}

# ---- the tripwire: this machine's own install, before anything runs --------
#
# install.sh deletes things, and some of what it deletes is named by absolute
# path or reached through the real user's launchd or systemd, whatever HOME
# says. On 2026-09-24 a case here ran a real uninstall with uname faked to
# Linux and deleted the developer's /Applications/agenthub-desktop.app. Every
# case below is confined by construction (sandboxed), and this is the check
# that the confinement held: the real install's app bundles, service units,
# trees, links, skills, data and log directories and startup files are
# recorded now and compared when the suite ends, however it ends. Identity is
# the inode (a deleted and recreated file is a different one) plus, for a
# startup file, its checksum, and for a link its target; a running node
# writing to its own database changes none of these.
developer_home="$HOME"
developer_claude="${CLAUDE_CONFIG_DIR:-$developer_home/.claude}"
developer_config="${XDG_CONFIG_HOME:-$developer_home/.config}"
developer_state="${XDG_STATE_HOME:-$developer_home/.local/state}"
developer_data="${XDG_DATA_HOME:-$developer_home/.local/share}"
developer_zdot="${ZDOTDIR:-$developer_home}"
tripwire_paths() {
	local slug
	for slug in agenthub agenthallway; do
		printf '%s\n' \
			"/Applications/$slug-desktop.app" \
			"$developer_home/Applications/$slug-desktop.app" \
			"$developer_home/Library/LaunchAgents/local.$slug.node.plist" \
			"$developer_config/systemd/user/$slug-node.service" \
			"$developer_home/.local/share/$slug" \
			"$developer_home/.local/bin/$slug-node" \
			"$developer_home/.local/bin/$slug-mcp" \
			"$developer_home/.local/bin/$slug-desktop" \
			"$developer_claude/skills/$slug-watch" \
			"$developer_home/.claude/skills/$slug-watch" \
			"$developer_home/Library/Application Support/$slug" \
			"$developer_home/Library/Application Support/$slug/node.key" \
			"$developer_config/$slug" \
			"$developer_config/$slug/node.key" \
			"$developer_home/Library/Logs/$slug" \
			"$developer_state/$slug" \
			"$developer_data/applications/$slug.desktop" \
			"$developer_config/fish/conf.d/$slug.fish" \
			"$developer_home/Library/Caches/com.wails.$slug-desktop" \
			"$developer_home/Library/WebKit/com.wails.$slug-desktop"
	done
	printf '%s\n' "$developer_home/.local/bin/ah" "$developer_zdot/.zshrc" "$developer_home/.bashrc" \
		"$developer_home/.bash_profile" "$developer_home/.bash_login" "$developer_home/.profile"
}
# inode_of prints a path's own inode number, not following a symlink.
inode_of() { # inode_of <path>
	perl -e '@s = lstat($ARGV[0]); print $s[1]' "$1"
}
tripwire_snapshot() {
	local path kind
	while IFS= read -r path; do
		if [ -L "$path" ]; then
			kind="link $(inode_of "$path") -> $(readlink "$path")"
		elif [ -d "$path" ]; then
			kind="dir $(inode_of "$path")"
		elif [ -f "$path" ]; then
			kind="file $(inode_of "$path") $(cksum <"$path" 2>/dev/null || echo unreadable)"
		elif [ -e "$path" ]; then
			kind="other $(inode_of "$path")"
		else
			kind="absent"
		fi
		printf '%s\t%s\n' "$path" "$kind"
	done < <(tripwire_paths)
	# The services themselves: a bootout or a disable through the real
	# launchctl or systemctl changes the pid, or makes it disappear.
	if command -v launchctl >/dev/null 2>&1; then
		local label
		for label in local.agenthub.node local.agenthallway.node; do
			printf 'launchd %s\t%s\n' "$label" \
				"$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -E '^[[:space:]]*(pid|state) = ' | head -n 2 | tr -s ' \t\n' ' ')"
		done
	fi
	if command -v systemctl >/dev/null 2>&1; then
		printf 'systemd\t%s\n' "$(systemctl --user show -p MainPID -p ActiveState agenthub-node.service agenthallway-node.service 2>/dev/null | tr '\n' ' ')"
	fi
}
tripwire_before=$(tripwire_snapshot)
tripwire_checked=0
# tripwire_check compares the machine with what it was when the suite started.
# Run at the end, and from the EXIT trap when the suite ends early.
tripwire_check() {
	tripwire_checked=1
	local after
	after=$(tripwire_snapshot)
	if [ "$after" != "$tripwire_before" ]; then
		echo "  FAIL: TRIPWIRE: this machine's own install changed while the suite ran:" >&2
		diff <(printf '%s\n' "$tripwire_before") <(printf '%s\n' "$after") >&2 || true
		return 1
	fi
	return 0
}

# Nothing the developer's shell happens to export reaches a run: each of these
# names a directory or a release on its own, and install.sh reads them all.
# sandboxed() clears them again for every run; clearing them here as well keeps
# the harness's own reads (and any run that slipped past sandboxed) honest.
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME ZDOTDIR CODEX_HOME CLAUDE_CONFIG_DIR \
	AGENTHALLWAY_HOME AGENTHUB_HOME AGENTHALLWAY_VERSION AGENTHUB_VERSION \
	AGENTHALLWAY_APPLICATIONS AGENTHUB_APPLICATIONS AGENTHALLWAY_OS_RELEASE AGENTHALLWAY_LDCONFIG_PATHS

work=$(mktemp -d "${TMPDIR:-/tmp}/agenthallway-install-test.XXXXXX")
# Resolved, because the sandbox compares paths against it and a TMPDIR behind
# a symlink (/var -> /private/var on macOS) would otherwise be two spellings.
work=$(cd -P "$work" && pwd -P)
# u+w first: a case below makes a directory read-only, and a harness that
# fails before undoing it would otherwise leave it behind in TMPDIR. The
# tripwire runs here too when the suite ends early, so a case that escaped is
# reported however the suite stops.
on_exit() {
	local status=$?
	if [ "$tripwire_checked" -eq 0 ] && ! tripwire_check; then
		status=1
	fi
	chmod -R u+w "$work" 2>/dev/null
	rm -rf "$work"
	exit "$status"
}
trap on_exit EXIT

# install.sh puts a Claude Code skill under ${CLAUDE_CONFIG_DIR:-$HOME/.claude},
# and several runs below install for real without a HOME of their own. Pointed
# here for the whole suite, so no run can write into the developer's own
# ~/.claude; the skill cases set their own.
export CLAUDE_CONFIG_DIR="$work/claude"
export CODEX_HOME="$work/codex"

# ---- sandboxed: the only way a case runs install.sh ------------------------
#
# A fake HOME is not enough, and each row here is a way out of one:
#
#   /Applications/...app        absolute; a faked uname does not fake the disk.
#                               AGENTHALLWAY_APPLICATIONS and the pre-rename
#                               AGENTHUB_APPLICATIONS both point into $work,
#                               because install.sh falls back from one to the
#                               other and then to the real /Applications.
#   launchctl, systemctl        uid-scoped: the real user's launchd domain and
#                               user manager, whatever HOME says.
#   osascript                   quits a running app by name, at any path.
#   pgrep, pkill                real processes; their patterns are paths.
#   open, hdiutil, ditto,       real system tools.
#   xattr, update-desktop-database
#   schtasks, taskkill          not called by install.sh, shimmed anyway.
#   curl, wget                  the network: real runs install with --from or
#                               from SB_SERVE, a directory standing in for the
#                               release page; anything else fails.
#   XDG_*, ZDOTDIR              each names a directory on its own.
#   AGENTHALLWAY_HOME/VERSION,  inherited from the developer's shell; a case
#   AGENTHUB_HOME/VERSION       that wants one passes it through `env`.
#   CLAUDE_CONFIG_DIR,          the skill and the MCP configurations; both
#   CODEX_HOME                  exported into $work above, and checked here.
#   an ah on PATH               PATH is the case's shims, then the system
#                               shims, then /usr/bin:/bin:/usr/sbin:/sbin only.
#   TMPDIR                      install.sh's temp directory goes in $work too.
system_shims="$work/system-shims"
mkdir -p "$system_shims" "$work/tmp"
for shimmed in launchctl systemctl osascript open pkill hdiutil xattr update-desktop-database schtasks taskkill; do
	cat >"$system_shims/$shimmed" <<EOF
#!/bin/sh
echo "$shimmed \$*" >>"$work/system-shims.log"
case "$shimmed \$1" in
# Nothing is active: a run asks before it stops anything.
"systemctl --user")
	case "\$*" in *is-active*) exit 3 ;; esac
	;;
# A bundle the case puts at SB_DMG_SOURCE is what the image "contains".
"hdiutil attach")
	while [ "\$#" -gt 1 ]; do
		[ "\$1" = -mountpoint ] && mount_point=\$2
		shift
	done
	mkdir -p "\$mount_point"
	if [ -n "\${SB_DMG_SOURCE:-}" ]; then
		cp -R "\$SB_DMG_SOURCE"/. "\$mount_point"/
	fi
	;;
esac
exit 0
EOF
done
# pgrep says "not running" unless the case names a pattern that is, once:
# SB_RUNNING_ONCE is a pattern pgrep answers yes to on its first call only.
cat >"$system_shims/pgrep" <<EOF
#!/bin/sh
echo "pgrep \$*" >>"$work/system-shims.log"
if [ -n "\${SB_RUNNING_ONCE:-}" ] && [ "\$*" = "-f \$SB_RUNNING_ONCE" ] && [ ! -e "\$SB_RUNNING_ONCE_SEEN" ]; then
	: >"\$SB_RUNNING_ONCE_SEEN"
	exit 0
fi
exit 1
EOF
# ditto writes only into the work directory; anywhere else is a test that has
# escaped, and it says so instead of writing.
cat >"$system_shims/ditto" <<EOF
#!/bin/sh
echo "ditto \$*" >>"$work/system-shims.log"
case "\$2" in
"$work"/*) cp -R "\$1" "\$2" ;;
*) echo "ditto shim: refusing to write \$2 outside $work" >&2; exit 1 ;;
esac
EOF
# curl and wget serve from SB_SERVE, the release page of a case that downloads
# for real, and fail otherwise.
for fetcher in curl wget; do
	cat >"$system_shims/$fetcher" <<EOF
#!/bin/sh
echo "$fetcher \$*" >>"$work/system-shims.log"
destination=""
url=""
while [ "\$#" -gt 0 ]; do
	case "\$1" in
	-o | -O) destination=\$2; shift 2 ;;
	-*) shift ;;
	*) url=\$1; shift ;;
	esac
done
served="\${SB_SERVE:-}/\${url##*/}"
if [ -n "\${SB_SERVE:-}" ] && [ -f "\$served" ] && [ -n "\$destination" ]; then
	cp "\$served" "\$destination"
	exit 0
fi
echo "$fetcher shim: no network in these tests (\$url)" >&2
exit 22
EOF
done
chmod +x "$system_shims"/*
bare_path="$system_shims:/usr/bin:/bin:/usr/sbin:/sbin"

# An /Applications of the tests' own, holding an app a Linux uninstall must not
# touch: a .app is a macOS install, whatever directory it is in.
fake_applications="$work/Applications"
mkdir -p "$fake_applications/agenthub-desktop.app/Contents/MacOS"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$work/fake-app-ah.log" >"$fake_applications/agenthub-desktop.app/Contents/MacOS/ah"
chmod +x "$fake_applications/agenthub-desktop.app/Contents/MacOS/ah"

# sb_set holds NAME=value pairs a case wants in the run's environment on top
# of what sandboxed sets (AGENTHUB_HOME, say); it is emptied after each use.
sb_set=()

sandboxed_abort() {
	echo "sandboxed: $*; stopping the suite before install.sh runs outside it" >&2
	exit 2
}

# sandboxed <home> <command...> runs a command — install.sh, or `env ... sh
# install.sh` — with HOME=<home> and the rest of the confinement above. PATH
# is the caller's (case shims, a faked uname, then $bare_path), checked first:
# every entry is in $work or a system bin directory, and every tool install.sh
# can reach the machine through resolves inside $work.
sandboxed() {
	local home=$1
	shift
	local entry tool resolved
	while IFS= read -r entry; do
		case "$entry" in
		"$work"/* | /usr/bin | /bin | /usr/sbin | /sbin) ;;
		*) sandboxed_abort "PATH holds \"$entry\"" ;;
		esac
	done < <(printf '%s\n' "$PATH" | tr ':' '\n')
	hash -r
	for tool in launchctl systemctl osascript open pgrep pkill hdiutil ditto xattr update-desktop-database curl wget schtasks taskkill; do
		resolved=$(command -v "$tool" 2>/dev/null || true)
		case "$resolved" in
		"$work"/*) ;;
		*) sandboxed_abort "$tool resolves to \"$resolved\", not to a shim" ;;
		esac
	done
	case "$home" in
	"$work"/*) ;;
	*) sandboxed_abort "HOME would be $home" ;;
	esac
	case "${CLAUDE_CONFIG_DIR:-}:${CODEX_HOME:-}" in
	"$work"/*:"$work"/*) ;;
	*) sandboxed_abort "CLAUDE_CONFIG_DIR or CODEX_HOME is outside the work directory" ;;
	esac
	env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u ZDOTDIR \
		-u AGENTHALLWAY_HOME -u AGENTHUB_HOME -u AGENTHALLWAY_VERSION -u AGENTHUB_VERSION \
		HOME="$home" TMPDIR="$work/tmp" \
		AGENTHALLWAY_APPLICATIONS="${SB_APPLICATIONS:-$fake_applications}" \
		AGENTHUB_APPLICATIONS="${SB_APPLICATIONS:-$fake_applications}" \
		${sb_set[@]+"${sb_set[@]}"} "$@"
}


failures=0
checks=0

fail() {
	failures=$((failures + 1))
	echo "  FAIL: $*" >&2
}

contains() { # contains <label> <haystack file> <needle>
	checks=$((checks + 1))
	if ! grep -qF -- "$3" "$2"; then
		fail "$1: expected to find \"$3\""
	fi
}

lacks() { # lacks <label> <haystack file> <needle>
	checks=$((checks + 1))
	if grep -qF -- "$3" "$2"; then
		fail "$1: did not expect \"$3\""
	fi
}

# fake_uname builds a PATH shim so install.sh can be asked what it would do on a
# machine this is not. Only `uname` is faked; everything else resolves normally.
fake_uname() { # fake_uname <system> <machine> -> prints a directory for PATH
	local system=$1 machine=$2
	local shim="$work/shim-$system-$machine"
	mkdir -p "$shim"
	cat >"$shim/uname" <<EOF
#!/bin/sh
case "\${1:-}" in
-s) echo "$system" ;;
-m) echo "$machine" ;;
*) echo "$system" ;;
esac
EOF
	chmod +x "$shim/uname"
	echo "$shim"
}

# fake_ldconfig builds a PATH shim whose `ldconfig -p` reports one WebKit2GTK
# ABI, both, or neither. That answer decides which of the two Linux desktop
# archives install.sh downloads, so every Linux case below pins it rather than
# inheriting whatever the machine running these tests happens to have — the
# suite runs on developer laptops with no ldconfig at all and on runners that
# have one ABI today and the other after an image bump.
fake_ldconfig() { # fake_ldconfig <4.0|4.1|both|none> -> prints a directory for PATH
	local abi=$1
	local shim="$work/ldconfig-$abi"
	local lines=""
	case $abi in
	4.1) lines="\tlibwebkit2gtk-4.1.so.0 (libc6,x86-64) => /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0" ;;
	4.0) lines="\tlibwebkit2gtk-4.0.so.37 (libc6,x86-64) => /lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37" ;;
	both) lines="\tlibwebkit2gtk-4.1.so.0 (libc6,x86-64) => /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0\n\tlibwebkit2gtk-4.0.so.37 (libc6,x86-64) => /lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37" ;;
	none) lines="\tlibc.so.6 (libc6,x86-64) => /lib/x86_64-linux-gnu/libc.so.6" ;;
	*) echo "fake_ldconfig: unknown abi $abi" >&2; exit 1 ;;
	esac
	mkdir -p "$shim"
	cat >"$shim/ldconfig" <<EOF
#!/bin/sh
# Only -p is ever asked for; anything else would be a change in install.sh
# that this shim should be updated for rather than silently absorbed.
if [ "\${1:-}" != "-p" ]; then
	echo "fake ldconfig got \$*" >&2
	exit 1
fi
printf '%b\\n' "$lines"
EOF
	chmod +x "$shim/ldconfig"
	echo "$shim"
}

# fake_os_release writes the one file install.sh reads to decide which package
# manager to name in the WebKit hint.
fake_os_release() { # fake_os_release <id> [id_like] -> prints a file path
	local id=$1 like=${2:-}
	local file="$work/os-release-$id${like:+-$like}"
	{
		echo "NAME=\"$id\""
		echo "ID=$id"
		[ -z "$like" ] || echo "ID_LIKE=$like"
	} >"$file"
	echo "$file"
}

# fake_ah builds a PATH shim whose `ah` answers `--json service status` the way
# a real one would on a machine in the named state. install.sh asks that
# question before it re-registers the service, and a dry run has no installed
# ah of its own to ask, so this is the machine's existing one.
fake_ah() { # fake_ah <none|db|fail> [database path] -> prints a directory for PATH
	local mode=$1 db=${2:-}
	local shim="$work/ah-$mode"
	mkdir -p "$shim"
	case $mode in
	none)
		cat >"$shim/ah" <<'EOF'
#!/bin/sh
case "$*" in
*"service status"*) printf '{\n  "service": {\n    "Installed": false,\n    "Supported": true\n  }\n}\n' ;;
*) echo "ah (fake)" ;;
esac
EOF
		;;
	db)
		cat >"$shim/ah" <<EOF
#!/bin/sh
case "\$*" in
*"service status"*)
	printf '%s\n' '{' \\
		'  "service": {' \\
		'    "Arguments": [' \\
		'      "--db",' \\
		'      "$db"' \\
		'    ],' \\
		'    "Installed": true,' \\
		'    "Supported": true' \\
		'  }' \\
		'}'
	;;
*) echo "ah (fake)" ;;
esac
EOF
		;;
	fail)
		cat >"$shim/ah" <<'EOF'
#!/bin/sh
echo "ah: unknown flag --json" >&2
exit 2
EOF
		;;
	esac
	chmod +x "$shim/ah"
	echo "$shim"
}

# Every dry run gets an `ah` that reports no registered service, so the
# transcript is the same on a machine that has AgentHub installed and on one
# that does not. The cases that care put a different one in front of it.
no_service_ah=$(fake_ah none)

dry_run() { # dry_run <system> <machine> <output file> [args...]
	local system=$1 machine=$2 out=$3
	shift 3
	local shim home=${DRY_HOME:-$work/dry-home}
	shim=$(fake_uname "$system" "$machine")
	mkdir -p "$home"
	# LDCONFIG_SHIM goes first so it wins over a real ldconfig in /sbin.
	#
	# AGENTHALLWAY_OS_RELEASE defaults to a path that does not exist, so a run that
	# does not care which distribution it is on gets the same generic advice
	# everywhere. Without it these tests would read the os-release of whatever
	# machine runs them and assert different text on a laptop than in CI.
	#
	# LDCONFIG_PATHS overrides the candidate list install.sh walks. A PATH shim
	# cannot express "no ldconfig anywhere", because the probe also tries
	# /sbin/ldconfig and /usr/sbin/ldconfig by absolute path and a Linux runner
	# has one there; the cases that pin those two branches set this instead.
	#
	# A HOME of the suite's own (DRY_HOME): a dry run reads the registered unit,
	# the startup files and the MCP configurations it would act on, and the
	# transcript must not depend on the machine running it.
	PATH="${LDCONFIG_SHIM:+$LDCONFIG_SHIM:}${AH_SHIM:-$no_service_ah}:$shim:$bare_path" \
		sandboxed "$home" env \
		AGENTHALLWAY_OS_RELEASE="${OS_RELEASE_FILE:-$work/no-such-os-release}" \
		AGENTHALLWAY_LDCONFIG_PATHS="${LDCONFIG_PATHS:-}" \
		sh "$installer" --dry-run "$@" >"$out" 2>&1
}

# dry_run_fails is dry_run for the cases whose point is the refusal.
dry_run_fails() { # dry_run_fails <label> <system> <machine> <output file> [args...]
	local label=$1
	shift
	checks=$((checks + 1))
	if dry_run "$@"; then
		fail "$label: the run was expected to fail and did not"
	fi
}

# exists_path is -e that also says yes to a dangling symlink.
exists_path() {
	[ -e "$1" ] || [ -L "$1" ]
}

# The commands a dry run would actually execute are the lines it prefixes with
# "+". Advice it prints (the WebKit hint names an apt command) is not one of
# them, and asserting over the whole transcript would confuse the two.
commands_only() { # commands_only <transcript> <destination>
	grep '^+ ' "$1" >"$2" || true
}

echo "== darwin/arm64, desktop =="
dry_run Darwin arm64 "$work/darwin.txt" --version v0.1.0 --prefix "$work/pfx"
contains "prefix install names its own app path" "$work/darwin.txt" "Open $work/pfx/agenthub-desktop.app; it starts on a setup checklist."
lacks "prefix install does not say Applications" "$work/darwin.txt" "from Applications"
commands_only "$work/darwin.txt" "$work/darwin.cmds"
contains darwin "$work/darwin.txt" "agenthub-desktop_v0.1.0_darwin_universal.dmg"
contains darwin "$work/darwin.txt" "releases/download/v0.1.0/SHA256SUMS"
contains darwin "$work/darwin.txt" "compared with agenthub-desktop_v0.1.0_darwin_universal.dmg"
contains darwin "$work/darwin.cmds" "hdiutil attach -nobrowse -readonly -quiet"
contains darwin "$work/darwin.cmds" "ditto"
contains darwin "$work/darwin.cmds" "xattr -dr com.apple.quarantine"
contains darwin "$work/darwin.cmds" "$work/pfx/agenthub-desktop.app"
contains darwin "$work/darwin.cmds" "ah service install"
contains darwin "$work/darwin.cmds" "$work/pfx/bin/ah"
lacks darwin "$work/darwin.cmds" "sudo"
lacks darwin "$work/darwin.txt" "/Applications/agenthub-desktop.app"
lacks darwin "$work/darwin.txt" "$HOME/.local/bin"
# The digest is checked before the disk image is attached, not after: the point
# of verifying is to not touch an unverified file.
checks=$((checks + 1))
if [ "$(grep -n 'compared with' "$work/darwin.txt" | cut -d: -f1 | head -n1)" -gt \
	"$(grep -n 'hdiutil attach' "$work/darwin.txt" | cut -d: -f1 | head -n1)" ]; then
	fail "darwin: the checksum is compared after the image is attached"
fi

echo "== darwin/x86_64, --cli-only --no-service --no-open =="
dry_run Darwin x86_64 "$work/darwin-cli.txt" --version v0.1.0 --cli-only --no-service --no-open --prefix "$work/pfx"
commands_only "$work/darwin-cli.txt" "$work/darwin-cli.cmds"
contains darwin-cli "$work/darwin-cli.txt" "agenthub_v0.1.0_darwin_amd64.tar.gz"
contains darwin-cli "$work/darwin-cli.cmds" "$work/pfx/bin/agenthub-mcp"
lacks darwin-cli "$work/darwin-cli.cmds" "service install"
lacks darwin-cli "$work/darwin-cli.cmds" "hdiutil"
lacks darwin-cli "$work/darwin-cli.cmds" "open "
lacks darwin-cli "$work/darwin-cli.cmds" "sudo"

echo "== linux/x86_64, desktop =="
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
dry_run Linux x86_64 "$work/linux.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_SHIM
commands_only "$work/linux.txt" "$work/linux.cmds"
contains linux "$work/linux.txt" "agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
contains linux "$work/linux.txt" "compared with agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
contains linux "$work/linux.cmds" "tar -xzf"
contains linux "$work/linux.cmds" "$work/pfx/share/agenthub"
contains linux "$work/linux.cmds" "$work/pfx/bin/agenthub-desktop"
contains linux "$work/linux.cmds" "ah service install"
lacks linux "$work/linux.cmds" "sudo"
lacks linux "$work/linux.cmds" "hdiutil"

echo "== linux/aarch64 falls back to the command line archive =="
dry_run Linux aarch64 "$work/linux-arm.txt" --version v0.1.0 --prefix "$work/pfx"
commands_only "$work/linux-arm.txt" "$work/linux-arm.cmds"
contains linux-arm "$work/linux-arm.txt" "no desktop build exists for linux arm64"
contains linux-arm "$work/linux-arm.txt" "agenthub_v0.1.0_linux_arm64.tar.gz"
lacks linux-arm "$work/linux-arm.txt" "agenthub-desktop_v0.1.0"
lacks linux-arm "$work/linux-arm.cmds" "sudo"

# ---- the two Linux WebKit ABIs ---------------------------------------------
#
# WebKit2GTK 4.0 and 4.1 are different ABIs, a distribution ships one or the
# other, and a binary built for either exits at startup on the other with no
# window and nothing in a log. The release carries a build for each, and this is
# the code that decides which one a machine downloads: getting it wrong is the
# whole failure, and it is invisible until someone double-clicks the app.

echo "== a 4.0 machine downloads the 4.0 build =="
LDCONFIG_SHIM=$(fake_ldconfig 4.0)
dry_run Linux x86_64 "$work/wk40.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_SHIM
contains webkit40 "$work/wk40.txt" "agenthub-desktop_v0.1.0_linux_amd64_webkit40.tar.gz"
contains webkit40 "$work/wk40.txt" "this machine has WebKit2GTK 4.0"
contains webkit40 "$work/wk40.txt" "compared with agenthub-desktop_v0.1.0_linux_amd64_webkit40.tar.gz"
# The digest has to be checked against the file that was actually fetched.
lacks webkit40 "$work/wk40.txt" "compared with agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
# Nothing to install, so nothing to advise: the matching build was downloaded.
lacks webkit40 "$work/wk40.txt" "will not open"
lacks webkit40 "$work/wk40.txt" "apt install"

echo "== a 4.1 machine downloads the plain build =="
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
dry_run Linux x86_64 "$work/wk41.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_SHIM
contains webkit41 "$work/wk41.txt" "agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
lacks webkit41 "$work/wk41.txt" "_webkit40.tar.gz"
lacks webkit41 "$work/wk41.txt" "this machine has WebKit2GTK 4.0"
contains webkit41 "$work/wk41.txt" "this machine has WebKit2GTK 4.1; taking the build linked against it"
lacks webkit41 "$work/wk41.txt" "will not open"

echo "== both installed takes 4.1 =="
LDCONFIG_SHIM=$(fake_ldconfig both)
dry_run Linux x86_64 "$work/wkboth.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_SHIM
contains webkit-both "$work/wkboth.txt" "agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
lacks webkit-both "$work/wkboth.txt" "_webkit40.tar.gz"
contains webkit-both "$work/wkboth.txt" "this machine has both WebKit2GTK ABIs; taking the 4.1 build"

echo "== neither installed takes 4.1 and says what to install =="
LDCONFIG_SHIM=$(fake_ldconfig none)
dry_run Linux x86_64 "$work/wknone.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_SHIM
contains webkit-none "$work/wknone.txt" "agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
lacks webkit-none "$work/wknone.txt" "_webkit40.tar.gz"
contains webkit-none "$work/wknone.txt" "this machine has no WebKit2GTK runtime installed; taking the 4.1 build"
contains webkit-none "$work/wknone.txt" "no WebKit2GTK runtime was found"
contains webkit-none "$work/wknone.txt" "it will pick the 4.0 build"
# The install still happens; the missing runtime is a hint, not a refusal.
contains webkit-none "$work/wknone.txt" "ah service install"
# With no os-release to read, the advice cannot name a package manager and must
# not pretend to.
contains webkit-none "$work/wknone.txt" "with your package manager"

echo "== the hint names the right package for the distribution =="
# These names do not follow from the version number — 4.1 is
# libwebkit2gtk-4.1-0 on Debian and webkit2gtk4.1 on Fedora — so each branch is
# asserted rather than assumed. This text is the only thing a person whose app
# will not start has to go on.
LDCONFIG_SHIM=$(fake_ldconfig none)
for distro_case in "ubuntu:debian:apt install libgtk-3-0 libwebkit2gtk-4.1-0" \
	"debian::apt install libgtk-3-0 libwebkit2gtk-4.1-0" \
	"fedora::dnf install gtk3 webkit2gtk4.1" \
	"arch::pacman -S gtk3 webkit2gtk-4.1"; do
	distro_id=${distro_case%%:*}
	distro_rest=${distro_case#*:}
	distro_like=${distro_rest%%:*}
	distro_want=${distro_rest#*:}
	OS_RELEASE_FILE=$(fake_os_release "$distro_id" "$distro_like")
	dry_run Linux x86_64 "$work/hint-$distro_id.txt" --version v0.1.0 --prefix "$work/pfx"
	unset OS_RELEASE_FILE
	contains "hint-$distro_id" "$work/hint-$distro_id.txt" "$distro_want"
done
unset LDCONFIG_SHIM

# The probe reads `ldconfig`, and on Debian and its derivatives /sbin is not on
# a non-root PATH — which is the machine this whole mechanism exists for. These
# two cases are the ones a developer laptop and a root CI runner both fail to
# be, so they pin the candidate list rather than the PATH.
echo "== ldconfig only at an absolute path is still read =="
sbin_only=$(fake_ldconfig 4.0)
LDCONFIG_PATHS="$work/absent/ldconfig $sbin_only/ldconfig"
dry_run Linux x86_64 "$work/wksbin.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_PATHS
contains webkit-sbin "$work/wksbin.txt" "agenthub-desktop_v0.1.0_linux_amd64_webkit40.tar.gz"
contains webkit-sbin "$work/wksbin.txt" "this machine has WebKit2GTK 4.0; taking the build linked against it"
lacks webkit-sbin "$work/wksbin.txt" "could not read this machine's WebKit2GTK ABI"
lacks webkit-sbin "$work/wksbin.txt" "will not open"

echo "== no ldconfig anywhere says so instead of going quiet =="
# The silent version of this is the original bug in another costume: the 4.1
# archive taken on a 4.0 machine with nothing printed at all.
LDCONFIG_PATHS="$work/absent/ldconfig"
OS_RELEASE_FILE=$(fake_os_release ubuntu debian)
dry_run Linux x86_64 "$work/wknold.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_PATHS OS_RELEASE_FILE
contains webkit-noldconfig "$work/wknold.txt" "agenthub-desktop_v0.1.0_linux_amd64.tar.gz"
lacks webkit-noldconfig "$work/wknold.txt" "_webkit40.tar.gz"
contains webkit-noldconfig "$work/wknold.txt" "could not read this machine's WebKit2GTK ABI (no readable ldconfig); taking the 4.1 build"
# Not silent afterwards either: the package hint is what the reader needs, and
# it must not claim the runtime is missing, only that it could not be read.
contains webkit-noldconfig "$work/wknold.txt" "could not be read (no readable ldconfig)"
contains webkit-noldconfig "$work/wknold.txt" "apt install libgtk-3-0 libwebkit2gtk-4.1-0"

# Every case above either shims ldconfig onto PATH or pins the candidate list,
# so none of them would notice the list shrinking back to PATH alone — which is
# the whole defect: a Debian 12 shell has no /sbin on PATH. Assert the literal.
# shellcheck disable=SC2016 # the literal default, not an expansion
contains webkit-paths "$installer" '${AGENTHALLWAY_LDCONFIG_PATHS:-ldconfig /sbin/ldconfig /usr/sbin/ldconfig}'
lacks webkit-noldconfig "$work/wknold.txt" "no WebKit2GTK runtime was found"

echo "== --cli-only never probes for a window it is not installing =="
LDCONFIG_SHIM=$(fake_ldconfig 4.0)
dry_run Linux x86_64 "$work/wkcli.txt" --version v0.1.0 --prefix "$work/pfx" --cli-only
unset LDCONFIG_SHIM
contains webkit-cli "$work/wkcli.txt" "agenthub_v0.1.0_linux_amd64.tar.gz"
lacks webkit-cli "$work/wkcli.txt" "_webkit40.tar.gz"
lacks webkit-cli "$work/wkcli.txt" "this machine has WebKit2GTK 4.0"

echo "== --from does not claim to have chosen the archive =="
# The 4.0 probe still runs (the hint depends on it), but an archive named on the
# command line was not picked by it.
LDCONFIG_SHIM=$(fake_ldconfig 4.0)
dry_run_fails "from-nonexistent" Linux x86_64 "$work/from.txt" --from "$work/no-such.tar.gz"
unset LDCONFIG_SHIM
lacks from-claim "$work/from.txt" "taking the build linked against it"

echo "== the applications menu gets an entry =="
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
dry_run Linux x86_64 "$work/entry.txt" --version v0.1.0 --prefix "$work/pfx"
unset LDCONFIG_SHIM
commands_only "$work/entry.txt" "$work/entry.cmds"
contains menu "$work/entry.cmds" "applications"
contains menu "$work/entry.txt" "agenthub.desktop"
# A command line install has no window to launch, so it leaves no menu entry
# behind for someone to click and watch do nothing.
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
dry_run Linux x86_64 "$work/entry-cli.txt" --version v0.1.0 --prefix "$work/pfx" --cli-only
unset LDCONFIG_SHIM
lacks menu-cli "$work/entry-cli.txt" "agenthub.desktop"
# Neither does macOS: it has a .app, and a .desktop file there is litter.
dry_run Darwin arm64 "$work/entry-mac.txt" --version v0.1.0 --prefix "$work/pfx"
lacks menu-darwin "$work/entry-mac.txt" "agenthub.desktop"

echo "== the latest release is looked up when no version is given =="
dry_run Linux x86_64 "$work/latest.txt" --prefix "$work/pfx"
contains latest "$work/latest.txt" "api.github.com/repos/SheldonChangL/agenthub/releases/latest"

echo "== --help and a bad flag =="
checks=$((checks + 1))
sh "$installer" --help >"$work/help.txt" 2>&1 || fail "--help exited non-zero"
contains help "$work/help.txt" "--cli-only"
contains help "$work/help.txt" "--no-skill"
contains help "$work/help.txt" "It never uses sudo."
checks=$((checks + 1))
if sh "$installer" --nonsense >"$work/bad.txt" 2>&1; then
	fail "an unknown flag was accepted"
fi
contains bad-flag "$work/bad.txt" "unknown option --nonsense"

# ---- real installs from a local archive, no network ------------------------

echo "== a real --from install, and a real refusal =="
staging="$work/stage/agenthub-desktop_v0.1.0_linux_amd64"
mkdir -p "$staging"
for binary in ah agenthub-node agenthub-mcp agenthub-desktop; do
	printf '#!/bin/sh\necho "%s v0.1.0 (fake)"\n' "$binary" >"$staging/$binary"
	chmod +x "$staging/$binary"
done
echo "fake" >"$staging/README.txt"
good="$work/good"
mkdir -p "$good"
tar -C "$work/stage" -czf "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	agenthub-desktop_v0.1.0_linux_amd64
(
	cd "$good"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum agenthub-desktop_v0.1.0_linux_amd64.tar.gz >SHA256SUMS
	else
		shasum -a 256 agenthub-desktop_v0.1.0_linux_amd64.tar.gz >SHA256SUMS
	fi
)

shim=$(fake_uname Linux x86_64)
target="$work/real"
# Each of these is a real install, so each runs sandboxed, with a HOME of its
# own: --prefix keeps what it installs inside the prefix, and the retirement
# of a pre-rename install makes "touches nothing outside it" something to
# prove rather than assume.
real_runs_home="$work/real-runs-home"
mkdir -p "$real_runs_home"
# XDG_DATA_HOME is redirected into the work directory for every real install
# below. Without it these runs — faked into being Linux — write a real
# ~/.local/share/applications/agenthub.desktop on the machine running the
# tests, pointing Exec= into a temp directory that is deleted on the next line
# of this script: a dead launcher entry left behind by a test suite. It also
# makes the entry readable here, which is the only way its body gets asserted
# at all.
xdg="$work/xdg"
PATH="$shim:$bare_path" sandboxed "$real_runs_home" env XDG_DATA_HOME="$xdg" sh "$installer" \
	--from "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	--prefix "$target" --no-service --no-open >"$work/real.txt" 2>&1
contains real "$work/real.txt" "verified agenthub-desktop_v0.1.0_linux_amd64.tar.gz against SHA256SUMS"
for binary in ah agenthub-node agenthub-mcp agenthub-desktop; do
	checks=$((checks + 1))
	[ -x "$target/share/agenthub/$binary" ] || fail "real: $binary is missing from the install"
done
checks=$((checks + 1))
[ -L "$target/bin/ah" ] || fail "real: $target/bin/ah is not a symlink"
checks=$((checks + 1))
[ "$("$target/bin/ah")" = "ah v0.1.0 (fake)" ] || fail "real: the linked ah is not the installed one"

# ---- the menu entry that was actually written ------------------------------

# The dry run proves the entry is written; only a real install can say what is
# in it. A launcher reads exactly these keys, and every one of them is silently
# wrong in its own way: a broken Exec= gives a menu item that does nothing, a
# missing StartupWMClass= gives a window that docks under a second icon.
entry="$xdg/applications/agenthub.desktop"
contains menu-body "$work/real.txt" "wrote $entry"
checks=$((checks + 1))
[ -f "$entry" ] || fail "real: no menu entry at $entry"
# It goes where XDG_DATA_HOME says and nowhere else. This assertion is the one
# that keeps the suite from littering the machine that runs it.
home_entry="${HOME:-/nonexistent}/.local/share/applications/agenthub.desktop"
checks=$((checks + 1))
if [ -f "$home_entry" ] && grep -qF -- "$work" "$home_entry"; then
	fail "real: the install wrote $home_entry pointing into this suite's work directory"
fi
contains menu-body "$entry" "[Desktop Entry]"
contains menu-body "$entry" "Type=Application"
contains menu-body "$entry" "Name=AgentHub"
contains menu-body "$entry" "Exec=\"$target/share/agenthub/agenthub-desktop\""
contains menu-body "$entry" "Terminal=false"
contains menu-body "$entry" "Categories=Development;"
contains menu-body "$entry" "StartupWMClass=agenthub-desktop"
# This archive ships no appicon.png, so Icon= must be absent rather than
# present and dangling: a launcher shows a broken-image placeholder for the
# second and its own generic icon for the first.
lacks menu-body "$entry" "Icon="

# An archive that does carry the icon names it, by absolute path inside the
# install tree. And the prefix here has a space in it, which is what makes the
# quoting of Exec= load-bearing: unquoted, a launcher reads the path as a
# command plus an argument and starts nothing.
spaced_stage="$work/stage-icon/agenthub-desktop_v0.1.0_linux_amd64"
mkdir -p "$spaced_stage"
for binary in ah agenthub-node agenthub-mcp agenthub-desktop; do
	printf '#!/bin/sh\necho "%s v0.1.0 (fake)"\n' "$binary" >"$spaced_stage/$binary"
	chmod +x "$spaced_stage/$binary"
done
printf 'not really a png\n' >"$spaced_stage/appicon.png"
iconed="$work/iconed"
mkdir -p "$iconed"
tar -C "$work/stage-icon" -czf "$iconed/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	agenthub-desktop_v0.1.0_linux_amd64
spaced_target="$work/a prefix with spaces"
spaced_xdg="$work/xdg spaced"
PATH="$shim:$bare_path" sandboxed "$real_runs_home" env XDG_DATA_HOME="$spaced_xdg" sh "$installer" \
	--from "$iconed/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	--prefix "$spaced_target" --no-service --no-open >"$work/real-icon.txt" 2>&1
spaced_entry="$spaced_xdg/applications/agenthub.desktop"
checks=$((checks + 1))
[ -f "$spaced_entry" ] || fail "icon: no menu entry at $spaced_entry"
contains menu-icon "$spaced_entry" "Exec=\"$spaced_target/share/agenthub/agenthub-desktop\""
contains menu-icon "$spaced_entry" "Icon=$spaced_target/share/agenthub/appicon.png"
checks=$((checks + 1))
[ -x "$spaced_target/share/agenthub/agenthub-desktop" ] ||
	fail "icon: the install under a path with spaces left no desktop binary"

# Re-running upgrades in place rather than failing on what is already there.
PATH="$shim:$bare_path" sandboxed "$real_runs_home" env XDG_DATA_HOME="$xdg" sh "$installer" \
	--from "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	--prefix "$target" --no-service --no-open >"$work/real2.txt" 2>&1
contains rerun "$work/real2.txt" "verified agenthub-desktop_v0.1.0_linux_amd64.tar.gz against SHA256SUMS"
checks=$((checks + 1))
[ -x "$target/share/agenthub/ah" ] || fail "rerun: the second install left no ah"

# A SHA256SUMS that does not match must stop the install, and must stop it
# before anything is unpacked.
bad="$work/bad"
mkdir -p "$bad"
cp "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" "$bad/"
printf '%s  %s\n' \
	"0000000000000000000000000000000000000000000000000000000000000000" \
	"agenthub-desktop_v0.1.0_linux_amd64.tar.gz" >"$bad/SHA256SUMS"
refused="$work/refused"
checks=$((checks + 1))
if PATH="$shim:$bare_path" sandboxed "$real_runs_home" env XDG_DATA_HOME="$xdg" sh "$installer" \
	--from "$bad/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	--prefix "$refused" --no-service --no-open >"$work/bad-sums.txt" 2>&1; then
	fail "a corrupted SHA256SUMS was accepted"
fi
contains bad-sums "$work/bad-sums.txt" "checksum mismatch"
contains bad-sums "$work/bad-sums.txt" "Nothing was installed."
checks=$((checks + 1))
[ ! -e "$refused" ] || fail "the refused install still created $refused"

# A SHA256SUMS that simply has no line for this file is the same refusal: an
# unverifiable download is not a verified one.
missing="$work/missing"
mkdir -p "$missing"
cp "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" "$missing/"
printf '%s  %s\n' \
	"0000000000000000000000000000000000000000000000000000000000000000" \
	"something-else.tar.gz" >"$missing/SHA256SUMS"
checks=$((checks + 1))
if PATH="$shim:$bare_path" sandboxed "$real_runs_home" env XDG_DATA_HOME="$xdg" sh "$installer" \
	--from "$missing/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	--prefix "$work/nope" --no-service --no-open >"$work/missing-sums.txt" 2>&1; then
	fail "a SHA256SUMS with no line for the file was accepted"
fi
contains missing-sums "$work/missing-sums.txt" "has no line for"

# ---- the existing service is carried, not overwritten ----------------------

# `ah service install` replaces the registration outright, and the database
# path lives nowhere else. A reinstall that does not carry --db forward gives
# the machine a new identity and drops every pairing, silently. These three
# are the whole contract: carry it, or do not touch the service at all.

echo "== an existing service keeps its database =="
AH_SHIM=$(fake_ah db /some/where.db)
dry_run Darwin arm64 "$work/svc-db.txt" --version v0.1.0 --prefix "$work/pfx"
unset AH_SHIM
commands_only "$work/svc-db.txt" "$work/svc-db.cmds"
contains svc-db "$work/svc-db.cmds" "service install --db /some/where.db"
contains svc-db "$work/svc-db.txt" "keeping the node's database at /some/where.db"
contains svc-db "$work/svc-db.txt" "the unit's node binary is replaced on purpose"

echo "== an unreadable service status installs no service =="
AH_SHIM=$(fake_ah fail)
dry_run Darwin arm64 "$work/svc-fail.txt" --version v0.1.0 --prefix "$work/pfx"
unset AH_SHIM
commands_only "$work/svc-fail.txt" "$work/svc-fail.cmds"
lacks svc-fail "$work/svc-fail.cmds" "service install"
contains svc-fail "$work/svc-fail.txt" "could not read the current background service"
contains svc-fail "$work/svc-fail.txt" "service install --db <path to the node's database>"
# The app is still installed: an unreadable service is a reason not to touch
# the service, not a reason to leave half an app behind.
contains svc-fail "$work/svc-fail.cmds" "ditto"

echo "== no registered service installs a plain one =="
dry_run Darwin arm64 "$work/svc-none.txt" --version v0.1.0 --prefix "$work/pfx"
commands_only "$work/svc-none.txt" "$work/svc-none.cmds"
contains svc-none "$work/svc-none.cmds" "service install"
lacks svc-none "$work/svc-none.cmds" "service install --db"

# ---- a truncated stream must run nothing -----------------------------------

# This is what `curl | sh` fails as: the connection drops and the shell is
# handed half a file. Everything with an effect is inside main(), and main is
# called on the last line, so half a file defines functions and calls none.
echo "== a truncated script runs nothing =="
installer_bytes=$(wc -c <"$installer")
installer_lines=$(wc -l <"$installer")
truncate_at() { # truncate_at <label> <byte count>
	local label=$1 bytes=$2
	head -c "$bytes" "$installer" >"$work/trunc-$label.sh"
}
truncate_at 60pct $((installer_bytes * 60 / 100))
truncate_at 90pct $((installer_bytes * 90 / 100))
sed -n "1,$((installer_lines - 5))p" "$installer" >"$work/trunc-tail.sh"

uname_shim=$(fake_uname Darwin arm64)
mkdir -p "$work/dry-home"
for cut in 60pct 90pct tail; do
	trunc_prefix="$work/trunc-prefix-$cut"
	PATH="$no_service_ah:$uname_shim:$bare_path" sandboxed "$work/dry-home" sh "$work/trunc-$cut.sh" \
		--dry-run --version v0.1.0 --prefix "$trunc_prefix" \
		>"$work/trunc-$cut.txt" 2>&1 || true
	commands_only "$work/trunc-$cut.txt" "$work/trunc-$cut.cmds"
	checks=$((checks + 1))
	if [ -s "$work/trunc-$cut.cmds" ]; then
		fail "truncated at $cut: it still ran commands"
	fi
	checks=$((checks + 1))
	[ ! -e "$trunc_prefix" ] || fail "truncated at $cut: it created $trunc_prefix"
done
# shellcheck disable=SC2016 # the literal last line of install.sh
contains truncation "$installer" 'main "$@"'

# ---- a directory this script did not create is not deleted -----------------

# AGENTHUB_HOME and --prefix are documented knobs, and `rm -rf` is downstream
# of both. Each of these printed a `rm -rf` of the named directory before.
echo "== a prefix that is not ours is refused =="
guard() { # guard <label> <message> [installer args...]
	local label=$1 message=$2
	shift 2
	dry_run_fails "$label" Linux x86_64 "$work/guard-$label.txt" "$@"
	commands_only "$work/guard-$label.txt" "$work/guard-$label.cmds"
	contains "$label" "$work/guard-$label.txt" "$message"
	lacks "$label" "$work/guard-$label.cmds" "rm"
}
# A dry run's HOME is the suite's own (dry_run), so that is the home these
# point at.
guard root "this script installs into a directory of its own" --prefix /
guard home "is your home directory" --prefix "$work/dry-home"
guard above-home "contains your home directory" --prefix "$work"

notours="$work/notours"
mkdir -p "$notours"
echo "someone else's file" >"$notours/thesis.txt"
guard foreign "holds no Agent Hallway install" --prefix "$notours"
checks=$((checks + 1))
[ -f "$notours/thesis.txt" ] || fail "the refused prefix lost a file"

echo "== AGENTHUB_HOME pointing somewhere else is refused =="
checks=$((checks + 1))
sb_set=(AGENTHUB_HOME="$notours")
if dry_run Linux x86_64 "$work/guard-agenthub-home.txt" \
	--version v0.1.0 --prefix "$work/pfx-ah"; then
	fail "AGENTHUB_HOME pointing at a foreign directory was accepted"
fi
sb_set=()
commands_only "$work/guard-agenthub-home.txt" "$work/guard-agenthub-home.cmds"
contains agenthub-home "$work/guard-agenthub-home.txt" "holds no AgentHub install"
lacks agenthub-home "$work/guard-agenthub-home.cmds" "+ rm "

echo "== HOME unset is a message, not an unbound variable =="
checks=$((checks + 1))
if env -u HOME PATH="$no_service_ah:$uname_shim:$bare_path" sh "$installer" \
	--dry-run --version v0.1.0 >"$work/no-home.txt" 2>&1; then
	fail "an unset HOME was accepted"
fi
contains no-home "$work/no-home.txt" "HOME is not set"
lacks no-home "$work/no-home.txt" "unbound variable"

# ---- the cleanup trap never rm -rf's an empty path -------------------------

# mktemp is shimmed to succeed while printing nothing, which is the shape that
# puts an empty string into TEMP_DIR after the trap is armed. rm is shimmed to
# record rather than delete, so a missing guard is a line in a log rather than
# a deleted directory.
echo "== the cleanup trap guards its variables =="
# shellcheck disable=SC2016 # the literal text of the guard, not an expansion
contains cleanup-guard "$installer" '[ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]'
trap_shim="$work/shim-trap"
mkdir -p "$trap_shim"
printf '#!/bin/sh\nexit 0\n' >"$trap_shim/mktemp"
cat >"$trap_shim/rm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/rm.log"
EOF
chmod +x "$trap_shim/mktemp" "$trap_shim/rm"
: >"$work/rm.log"
checks=$((checks + 1))
if PATH="$trap_shim:$no_service_ah:$uname_shim:$bare_path" sandboxed "$work/dry-home" sh "$installer" \
	--from "$work/no-such-archive.tar.gz" --prefix "$work/pfx-trap" --no-service \
	>"$work/trap.txt" 2>&1; then
	fail "a --from that is not a file was accepted"
fi
contains trap "$work/trap.txt" "is not a file"
checks=$((checks + 1))
[ ! -s "$work/rm.log" ] || fail "the cleanup trap ran rm with an empty TEMP_DIR: $(cat "$work/rm.log")"

# ---- ~/.local/bin ends up on PATH ------------------------------------------

# macOS puts no ~/.local/bin on PATH, so a default install that only printed a
# hint ended with `ah: command not found`. These runs use a HOME of their own —
# without --prefix the installer writes under HOME, and the startup file it
# appends to is the owner's real one otherwise — and a PATH that cannot already
# hold that HOME's bin directory.
echo "== a default install puts ~/.local/bin on PATH =="
# bare_path (defined with the system shims above) puts launchctl, systemctl
# and the rest on every PATH built from it: an uninstall that finds a unit
# with no ah left takes it down with them, and the machine running these
# tests has a real user manager of its own.
path_home="$work/path-home"
mkdir -p "$path_home"
# shellcheck disable=SC2016 # the literal line the installer writes
export_line='export PATH="$HOME/.local/bin:$PATH"'

path_dry() { # path_dry <output file> <shell> [args...]
	local out=$1 shell=$2
	shift 2
	PATH="$no_service_ah:$(fake_uname Darwin arm64):$bare_path" SHELL="$shell" \
		sandboxed "$path_home" sh "$installer" --dry-run --version v0.1.0 "$@" >"$out" 2>&1
}
path_dry "$work/path-zsh.txt" /bin/zsh --no-service --no-open
contains path-zsh "$work/path-zsh.txt" "+ append to $path_home/.zshrc: $export_line"
contains path-zsh "$work/path-zsh.txt" "PATH: on PATH in new terminals"
lacks path-zsh "$work/path-zsh.txt" "is not on your PATH"
checks=$((checks + 1))
[ ! -e "$path_home/.zshrc" ] || fail "path-zsh: a dry run wrote $path_home/.zshrc"
path_dry "$work/path-bash-mac.txt" /bin/bash --no-service --no-open
contains path-bash-mac "$work/path-bash-mac.txt" "+ append to $path_home/.bash_profile: "
path_dry "$work/path-noshell.txt" "" --no-service --no-open
contains path-noshell "$work/path-noshell.txt" "+ append to $path_home/.zshrc: "
path_dry "$work/path-optout.txt" /bin/zsh --no-service --no-open --no-modify-path
contains path-optout "$work/path-optout.txt" "note: $path_home/.local/bin is not on your PATH"
lacks path-optout "$work/path-optout.txt" "append to"
path_dry "$work/path-tcsh.txt" /bin/tcsh --no-service --no-open
contains path-tcsh "$work/path-tcsh.txt" "is not on your PATH. Add it"
contains path-tcsh "$work/path-tcsh.txt" "PATH: not on PATH"
lacks path-tcsh "$work/path-tcsh.txt" "append to"
# A bash login shell reads only the first of .bash_profile, .bash_login and
# .profile that exists; a new .bash_profile would switch an existing .profile off.
profile_home="$work/profile-home"
mkdir -p "$profile_home"
echo 'export FROM_PROFILE=1' >"$profile_home/.profile"
PATH="$no_service_ah:$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/bash \
	sandboxed "$profile_home" sh "$installer" --dry-run --version v0.1.0 --no-service --no-open >"$work/path-profile.txt" 2>&1
contains path-profile "$work/path-profile.txt" "+ append to $profile_home/.profile: "
lacks path-profile "$work/path-profile.txt" ".bash_profile"
PATH="$no_service_ah:$(fake_uname Darwin arm64):$path_home/.local/bin:$bare_path" SHELL=/bin/zsh \
	sandboxed "$path_home" sh "$installer" --dry-run --version v0.1.0 --no-service --no-open >"$work/path-already.txt" 2>&1
lacks path-already "$work/path-already.txt" "append to"
lacks path-already "$work/path-already.txt" "is not on your PATH"
contains path-already "$work/path-already.txt" "PATH: on PATH"

# A real install without --prefix, into that HOME, run twice. What is asserted
# is the composition: a new shell that reads the startup file finds the `ah`
# this install linked — not merely that some line was written.
echo "== the startup file a real install writes finds ah =="
linux_shim=$(fake_uname Linux x86_64)
path_real() { # path_real <output file> <shell> [args...]
	local out=$1 shell=$2
	shift 2
	PATH="$linux_shim:$bare_path" SHELL="$shell" \
		sandboxed "$path_home" env XDG_DATA_HOME="$work/path-xdg" ${path_real_env[@]+"${path_real_env[@]}"} sh "$installer" --from "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
		--no-service "$@" >"$out" 2>&1
}
checks=$((checks + 1))
path_real "$work/path-real.txt" /bin/bash || fail "path-real: the install failed: $(cat "$work/path-real.txt")"
contains path-real "$work/path-real.txt" "added $path_home/.local/bin to PATH in $path_home/.bashrc"
checks=$((checks + 1))
path_real "$work/path-real2.txt" /bin/bash || fail "path-real2: the second install failed"
contains path-real2 "$work/path-real2.txt" "$path_home/.bashrc already adds"
checks=$((checks + 1))
[ "$(grep -cF "$export_line" "$path_home/.bashrc")" -eq 1 ] ||
	fail "path-real: a second install added the line again: $(cat "$path_home/.bashrc")"
checks=$((checks + 1))
# shellcheck disable=SC2016 # expanded by the child shell, with its own HOME
found=$(env -i HOME="$path_home" PATH="$bare_path" bash -c '. "$HOME/.bashrc"; command -v ah' || true)
[ "$found" = "$path_home/.local/bin/ah" ] || fail "path-real: a shell reading .bashrc finds ah at \"$found\""
if command -v zsh >/dev/null 2>&1; then
	zdot="$work/path-zdot"
	mkdir -p "$zdot"
	checks=$((checks + 1))
	path_real_env=(ZDOTDIR="$zdot")
	path_real "$work/path-real-zsh.txt" /bin/zsh || fail "path-real-zsh: the install failed"
	path_real_env=()
	contains path-real-zsh "$work/path-real-zsh.txt" "to PATH in $zdot/.zshrc"
	checks=$((checks + 1))
	found=$(env -i HOME="$path_home" ZDOTDIR="$zdot" PATH="$bare_path" zsh -i -c 'command -v ah' 2>/dev/null || true)
	[ "$found" = "$path_home/.local/bin/ah" ] || fail "path-real-zsh: a new zsh finds ah at \"$found\""
fi
# A startup file that cannot be written is a warning, not the end of the
# install: the node still gets registered and the closing lines still print.
# Root writes through a read-only mode, so the case means nothing there.
if [ "$(id -u)" -ne 0 ]; then
	ro_home="$work/ro-home"
	mkdir -p "$ro_home"
	: >"$work/ro-bashrc"
	chmod 444 "$work/ro-bashrc"
	ln -s "$work/ro-bashrc" "$ro_home/.bashrc"
	checks=$((checks + 1))
	PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
		sandboxed "$ro_home" env XDG_DATA_HOME="$work/ro-xdg" sh "$installer" --from "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
		--no-service >"$work/path-ro.txt" 2>&1 || fail "path-ro: a read-only .bashrc stopped the install: $(cat "$work/path-ro.txt")"
	contains path-ro "$work/path-ro.txt" "warning: could not write $ro_home/.bashrc"
	contains path-ro "$work/path-ro.txt" "PATH: not on PATH"
	contains path-ro "$work/path-ro.txt" "skipped the background service"
	contains path-ro "$work/path-ro.txt" "done. AgentHub"
fi
rm -f "$path_home/.profile"
checks=$((checks + 1))
path_real "$work/path-real-optout.txt" /bin/sh --no-modify-path || fail "path-real-optout: the install failed"
checks=$((checks + 1))
[ ! -e "$path_home/.profile" ] || fail "path-real-optout: --no-modify-path wrote $path_home/.profile"

# ---- --uninstall -------------------------------------------------------------

# Every uninstall below runs sandboxed, with a HOME of its own: it deletes
# things under HOME, and the one running these tests is the developer's. HOME
# is not the only way out, either (see sandboxed): an earlier draft of these
# tests deleted the developer's /Applications/agenthub-desktop.app. The
# fake /Applications set up with the sandbox holds a pre-rename app that a
# Linux uninstall must not touch.

# uninstall_ah_script writes an ah that records what it was asked and answers
# `--json service status` with a registered unit using <db>. <status> is the
# exit code for `service uninstall`.
uninstall_ah_script() { # uninstall_ah_script <file> <log> <db> <status>
	cat >"$1" <<EOF
#!/bin/sh
echo "\$*" >>"$2"
case "\$*" in
*"service status"*)
	printf '%s\n' '{"service":{"Installed":true,"Supported":true,"Arguments":["--db","$3"]}}'
	;;
*"service uninstall"*) exit $4 ;;
esac
EOF
	chmod +x "$1"
}

# make_unit writes the registration `ah service install` would, starting
# <node binary>: a launchd plist or a systemd unit, under <home>.
make_unit() { # make_unit <home> <darwin|linux> <node binary> [db]
	local home=$1 os=$2 node=$3 db=${4:-}
	if [ "$os" = darwin ]; then
		mkdir -p "$home/Library/LaunchAgents"
		{
			printf '<plist version="1.0">\n<dict>\n\t<key>ProgramArguments</key>\n\t<array>\n'
			printf '\t\t<string>%s</string>\n' "$node"
			[ -z "$db" ] || printf '\t\t<string>--db</string>\n\t\t<string>%s</string>\n' "$db"
			printf '\t</array>\n</dict>\n</plist>\n'
		} >"$home/Library/LaunchAgents/local.agenthub.node.plist"
	else
		mkdir -p "$home/.config/systemd/user"
		printf '[Service]\nExecStart=%s%s\n' "$node" "${db:+ --db $db}" \
			>"$home/.config/systemd/user/agenthub-node.service"
	fi
}

echo "== --uninstall takes back what a real install put in place =="
un_home="$work/un-home"
mkdir -p "$un_home/.local/bin"
printf 'alias keep=1\n\n# the owner'"'"'s own\n' >"$un_home/.bashrc"
cp "$un_home/.bashrc" "$work/un-bashrc.before"
ln -s /usr/bin/true "$un_home/.local/bin/agenthub-mcp"
un_run() { # un_run <output file> [args...]
	local out=$1
	shift
	PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
		sandboxed "$un_home" sh "$installer" "$@" >"$out" 2>&1
}
checks=$((checks + 1))
un_run "$work/un-install.txt" --from "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" --no-service ||
	fail "un: the install failed: $(cat "$work/un-install.txt")"
uninstall_ah_script "$un_home/.local/share/agenthub/ah" "$work/un-ah.log" "$un_home/.config/agenthub/agenthub.db" 0
make_unit "$un_home" linux "$un_home/.local/share/agenthub/agenthub-node" "$un_home/.config/agenthub/agenthub.db"
mkdir -p "$un_home/.config/agenthub" "$un_home/.local/state/agenthub"
echo key >"$un_home/.config/agenthub/node.key"
echo db >"$un_home/.config/agenthub/agenthub.db"
echo log >"$un_home/.local/state/agenthub/node.log"
checks=$((checks + 1))
[ -f "$un_home/.local/share/applications/agenthub.desktop" ] || fail "un: the install wrote no menu entry to take back"
checks=$((checks + 1))
un_run "$work/un.txt" --uninstall || fail "un: --uninstall failed: $(cat "$work/un.txt")"
contains un "$work/un-ah.log" "service uninstall"
lacks un "$work/un.txt" "/Applications"
for gone in .local/share/agenthub .local/bin/ah .local/bin/agenthub-desktop .local/share/applications/agenthub.desktop; do
	checks=$((checks + 1))
	! exists_path "$un_home/$gone" || fail "un: $gone is still there"
done
checks=$((checks + 1))
[ -L "$un_home/.local/bin/agenthub-mcp" ] || fail "un: a link that points elsewhere was removed"
contains un "$work/un.txt" "left $un_home/.local/bin/agenthub-mcp alone"
checks=$((checks + 1))
cmp -s "$un_home/.bashrc" "$work/un-bashrc.before" ||
	fail "un: .bashrc is not what it was before the install: $(od -c "$un_home/.bashrc" | head -5)"
checks=$((checks + 1))
[ -f "$un_home/.config/agenthub/node.key" ] || fail "un: --uninstall without --purge deleted node.key"
contains un "$work/un.txt" "--uninstall --purge"
contains un "$work/un.txt" "ah revoke"
checks=$((checks + 1))
[ -x "$fake_applications/agenthub-desktop.app/Contents/MacOS/ah" ] || fail "un: a Linux uninstall removed a macOS app bundle"
checks=$((checks + 1))
[ ! -e "$work/fake-app-ah.log" ] || fail "un: a Linux uninstall ran the ah inside a macOS app bundle: $(cat "$work/fake-app-ah.log")"
# With nothing installed and no service left, --purge takes the default data.
checks=$((checks + 1))
un_run "$work/un-purge.txt" --uninstall --purge || fail "un-purge: failed: $(cat "$work/un-purge.txt")"
for gone in .config/agenthub .local/state/agenthub; do
	checks=$((checks + 1))
	! exists_path "$un_home/$gone" || fail "un-purge: $gone is still there"
done
contains un-purge "$work/un-purge.txt" "installing again makes a new node"
lacks un-purge "$work/un-purge.txt" "/Applications"

# tree_at puts a minimal unpacked install at <dir>: the two binaries
# is_install_tree asks for, with <dir>/ah the given fake.
tree_at() { # tree_at <dir> <log> <db> <status>
	mkdir -p "$1"
	uninstall_ah_script "$1/ah" "$2" "$3" "$4"
	printf '#!/bin/sh\n' >"$1/agenthub-node"
	chmod +x "$1/agenthub-node"
}

# mac_bundle puts a minimal AgentHub.app at <app path>, its ah the given fake.
mac_bundle() { # mac_bundle <app path> <log>
	mkdir -p "$1/Contents/MacOS"
	uninstall_ah_script "$1/Contents/MacOS/ah" "$2" "" 0
	printf '#!/bin/sh\n' >"$1/Contents/MacOS/agenthub-node"
}

echo "== --purge of a database outside the default takes only its files =="
checkout="$work/checkout/agenthub"
purge_home="$work/purge-home"
mkdir -p "$checkout"
echo key >"$checkout/node.key"
echo db >"$checkout/agenthub.db"
echo db >"$checkout/agenthub.db-wal"
echo mine >"$checkout/README.md"
tree_at "$purge_home/.local/share/agenthub" "$work/purge-ah.log" "$checkout/agenthub.db" 0
make_unit "$purge_home" linux "$purge_home/.local/share/agenthub/agenthub-node" "$checkout/agenthub.db"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$purge_home" sh "$installer" --uninstall --purge >"$work/purge.txt" 2>&1 || fail "purge: failed: $(cat "$work/purge.txt")"
for gone in node.key agenthub.db agenthub.db-wal; do
	checks=$((checks + 1))
	[ ! -e "$checkout/$gone" ] || fail "purge: $gone is still there"
done
checks=$((checks + 1))
[ -f "$checkout/README.md" ] || fail "purge: a file of the owner's beside the database was deleted"

echo "== a service that is not this install's is left running =="
# The owner's own node, registered from a source checkout's bin/ah, while an
# install from this script is being removed: one registration per user, and it
# is not this install's to take down — nor is its data --purge's to delete.
foreign_home="$work/foreign-home"
tree_at "$foreign_home/.local/share/agenthub" "$work/foreign-ah.log" "" 0
make_unit "$foreign_home" linux "$work/src/agenthub/bin/agenthub-node"
mkdir -p "$foreign_home/.config/agenthub"
echo key >"$foreign_home/.config/agenthub/node.key"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$foreign_home" sh "$installer" --uninstall --purge >"$work/foreign.txt" 2>&1 || fail "foreign: failed: $(cat "$work/foreign.txt")"
: >>"$work/foreign-ah.log"
lacks foreign "$work/foreign-ah.log" "service uninstall"
contains foreign "$work/foreign.txt" "left the registered background service alone"
contains foreign "$work/foreign.txt" "left the node's identity and database alone"
lacks foreign "$work/foreign.txt" "sh -s -- --uninstall --purge"
checks=$((checks + 1))
[ -f "$foreign_home/.config/systemd/user/agenthub-node.service" ] || fail "foreign: the owner's unit was removed"
checks=$((checks + 1))
[ -f "$foreign_home/.config/agenthub/node.key" ] || fail "foreign: --purge deleted the data of a node that is not this install's"
checks=$((checks + 1))
! exists_path "$foreign_home/.local/share/agenthub" || fail "foreign: this install's own tree was not removed"

echo "== an ah on PATH is never the one that takes a service down =="
path_ah_home="$work/path-ah-home"
mkdir -p "$path_ah_home" "$work/path-ah-shim"
uninstall_ah_script "$work/path-ah-shim/ah" "$work/path-ah.log" "" 0
make_unit "$path_ah_home" linux "$work/src/agenthub/bin/agenthub-node"
checks=$((checks + 1))
PATH="$work/path-ah-shim:$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$path_ah_home" sh "$installer" --uninstall >"$work/path-ah.txt" 2>&1 || fail "path-ah: failed: $(cat "$work/path-ah.txt")"
checks=$((checks + 1))
[ ! -e "$work/path-ah.log" ] || fail "path-ah: the ah on PATH was run: $(cat "$work/path-ah.log")"

echo "== AGENTHUB_HOME at a directory that is not an install is left alone =="
# A source checkout has bin/ah, which holds_agenthub counts as an install.
not_tree="$work/src-checkout"
mkdir -p "$not_tree/bin" "$work/not-tree-home"
echo src >"$not_tree/bin/ah"
echo mine >"$not_tree/go.mod"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$work/not-tree-home" env AGENTHUB_HOME="$not_tree" sh "$installer" --uninstall >"$work/not-tree.txt" 2>&1 || fail "not-tree: failed: $(cat "$work/not-tree.txt")"
contains not-tree "$work/not-tree.txt" "left $not_tree alone"
checks=$((checks + 1))
[ -f "$not_tree/go.mod" ] || fail "not-tree: the checkout was removed"

echo "== with no ah left, this install's unit is taken down directly =="
# An install half-removed by hand: the tree's ah is gone, the unit is not.
# systemctl is a shim, so the runner's own user manager is never asked.
orphan_home="$work/orphan-home"
mkdir -p "$orphan_home/.local/share/agenthub" "$work/orphan-shim"
printf '#!/bin/sh\n' >"$orphan_home/.local/share/agenthub/agenthub-node"
make_unit "$orphan_home" linux "$orphan_home/.local/share/agenthub/agenthub-node"
printf '#!/bin/sh\necho "systemctl $*" >>"%s"\n' "$work/orphan-systemctl.log" >"$work/orphan-shim/systemctl"
chmod +x "$work/orphan-shim/systemctl"
# An ah on PATH is someone else's (a source build): even for a unit that is
# ours, it is not the one to run.
uninstall_ah_script "$work/orphan-shim/ah" "$work/orphan-path-ah.log" "" 0
checks=$((checks + 1))
PATH="$work/orphan-shim:$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$orphan_home" sh "$installer" --uninstall >"$work/orphan.txt" 2>&1 || fail "orphan: failed: $(cat "$work/orphan.txt")"
contains orphan "$work/orphan-systemctl.log" "systemctl --user disable --now agenthub-node.service"
checks=$((checks + 1))
! exists_path "$orphan_home/.config/systemd/user/agenthub-node.service" || fail "orphan: the unit is still there"
checks=$((checks + 1))
[ ! -e "$work/orphan-path-ah.log" ] || fail "orphan: the ah on PATH was run: $(cat "$work/orphan-path-ah.log")"

echo "== the unit is recognised however the path to this install is spelled =="
# The unit holds the path the node runs from as os.Executable reports it:
# symlinks resolved, no doubled or trailing slash. AGENTHUB_HOME here is a
# link to the tree with a trailing slash, and the unit names the real place.
spelled_home="$work/spelled-home"
spelled_real="$work/spelled-real/agenthub"
tree_at "$spelled_real" "$work/spelled-ah.log" "" 0
mkdir -p "$spelled_home"
ln -s "$spelled_real" "$work/spelled-link"
make_unit "$spelled_home" linux "$(cd -P "$spelled_real" && pwd -P)/agenthub-node"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$spelled_home" env AGENTHUB_HOME="$work/spelled-link/" sh "$installer" --uninstall >"$work/spelled.txt" 2>&1 || fail "spelled: failed: $(cat "$work/spelled.txt")"
contains spelled "$work/spelled-ah.log" "service uninstall"
lacks spelled "$work/spelled.txt" "left the registered background service alone"

echo "== escaped spellings: launchd XML and systemd quoting =="
# launchd: xml.EscapeText, so an apostrophe is &#39;. systemd: % doubled, and
# a path with a space or $ quoted with $ doubled (internal/service systemdQuote).
xml_home="$work/xml-home"
xml_pfx="$work/o'b\"r	x pfx"
mac_bundle "$xml_pfx/agenthub-desktop.app" "$work/xml-ah.log"
mkdir -p "$xml_home/Library/LaunchAgents"
printf '<plist>\n\t<array>\n\t\t<string>%s</string>\n\t</array>\n</plist>\n' \
	"$work/o&#39;b&#34;r&#x9;x pfx/agenthub-desktop.app/Contents/MacOS/agenthub-node" \
	>"$xml_home/Library/LaunchAgents/local.agenthub.node.plist"
checks=$((checks + 1))
PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh \
	sandboxed "$xml_home" sh "$installer" --uninstall --prefix "$xml_pfx" >"$work/xml.txt" 2>&1 || fail "xml: failed: $(cat "$work/xml.txt")"
contains xml "$work/xml-ah.log" "service uninstall"
# The same escaped path, but not as the program: unit_mentions_install must
# still see it and stop before the app a live service runs from is deleted.
xml2_home="$work/xml2-home"
mac_bundle "$xml_pfx/agenthub-desktop.app" "$work/xml2-ah.log"
mkdir -p "$xml2_home/Library/LaunchAgents"
# One <string> holding the program and a flag: not a form service_is_ours
# reads, still a mention of the install.
printf '<plist>\n\t<array>\n\t\t<string>%s --verbose</string>\n\t</array>\n</plist>\n' \
	"$work/o&#39;b&#34;r&#x9;x pfx/agenthub-desktop.app/Contents/MacOS/agenthub-node" \
	>"$xml2_home/Library/LaunchAgents/local.agenthub.node.plist"
checks=$((checks + 1))
if PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh \
	sandboxed "$xml2_home" sh "$installer" --uninstall --prefix "$xml_pfx" >"$work/xml2.txt" 2>&1; then
	fail "xml2: an escaped unit naming this install was carried past"
fi
contains xml2 "$work/xml2.txt" "nothing was removed"
checks=$((checks + 1))
[ -d "$xml_pfx/agenthub-desktop.app" ] || fail "xml2: the app a registered service runs from was deleted"
sd_home="$work/sd-home"
sd_tree="$work/pct%dir \$x/agenthub"
tree_at "$sd_tree" "$work/sd-ah.log" "" 0
mkdir -p "$sd_home/.config/systemd/user"
printf '[Service]\nExecStart="%s/agenthub-node" --db x\n' "$(printf '%s' "$sd_tree" | sed 's/%/%%/g; s/\$/$$/g')" \
	>"$sd_home/.config/systemd/user/agenthub-node.service"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$sd_home" env AGENTHUB_HOME="$sd_tree" sh "$installer" --uninstall >"$work/sd.txt" 2>&1 || fail "sd: failed: $(cat "$work/sd.txt")"
contains sd "$work/sd-ah.log" "service uninstall"
checks=$((checks + 1))
! exists_path "$sd_tree" || fail "sd: the tree is still there"

echo "== a unit that names this install but cannot be read stops the uninstall =="
unread_home="$work/unread-home"
tree_at "$unread_home/.local/share/agenthub" "$work/unread-ah.log" "" 0
mkdir -p "$unread_home/.config/systemd/user"
printf '[Service]\nExecStart=/usr/bin/env %s\n' "$unread_home/.local/share/agenthub/agenthub-node" \
	>"$unread_home/.config/systemd/user/agenthub-node.service"
checks=$((checks + 1))
if PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$unread_home" sh "$installer" --uninstall >"$work/unread.txt" 2>&1; then
	fail "unread: an unreadable unit naming this install was carried past"
fi
contains unread "$work/unread.txt" "nothing was removed"
checks=$((checks + 1))
[ -x "$unread_home/.local/share/agenthub/ah" ] || fail "unread: the tree a registered service runs from was deleted"

echo "== a checkout with both binaries built at its root is not an install =="
built="$work/built-checkout"
tree_at "$built" "$work/built-ah.log" "" 0
echo "module x" >"$built/go.mod"
mkdir -p "$work/built-home"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$work/built-home" env AGENTHUB_HOME="$built" sh "$installer" --uninstall >"$work/built.txt" 2>&1 || fail "built: failed: $(cat "$work/built.txt")"
checks=$((checks + 1))
[ -f "$built/go.mod" ] || fail "built: the checkout was removed"

git_checkout="$work/git-checkout"
tree_at "$git_checkout" "$work/git-ah.log" "" 0
mkdir -p "$git_checkout/.git"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$work/built-home" env AGENTHUB_HOME="$git_checkout" sh "$installer" --uninstall >"$work/git-built.txt" 2>&1 || fail "git-built: failed: $(cat "$work/git-built.txt")"
checks=$((checks + 1))
[ -d "$git_checkout/.git" ] || fail "git-built: the checkout was removed"

echo "== an app in an Applications this account cannot write is a warning =="
# The app went to ~/Applications at install time... or another administrator
# put one in /Applications. Either way it is looked at, and a directory this
# account cannot write stops nothing else. Root writes anyway, so not as root.
if [ "$(id -u)" -ne 0 ]; then
	ro_apps_home="$work/ro-apps-home"
	ro_apps="$work/ro-Applications"
	mac_bundle "$ro_apps/agenthub-desktop.app" "$work/ro-apps-ah.log"
	mkdir -p "$ro_apps_home"
	chmod 555 "$ro_apps"
	checks=$((checks + 1))
	PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh 		sandboxed "$ro_apps_home" env AGENTHALLWAY_APPLICATIONS="$ro_apps" sh "$installer" --uninstall >"$work/ro-apps.txt" 2>&1 ||
		fail "ro-apps: a directory it cannot write ended the uninstall: $(cat "$work/ro-apps.txt")"
	contains ro-apps "$work/ro-apps.txt" "could not remove $ro_apps/agenthub-desktop.app"
	contains ro-apps "$work/ro-apps.txt" "done, except for what could not be removed"
	lacks ro-apps "$work/ro-apps.txt" "done. Agent Hallway is uninstalled."
	chmod 755 "$ro_apps"
fi

echo "== an old unquoted menu entry is still this install's =="
old_entry_home="$work/old-entry-home"
tree_at "$old_entry_home/.local/share/agenthub" "$work/old-entry-ah.log" "" 0
mkdir -p "$old_entry_home/.local/share/applications"
printf '[Desktop Entry]\nExec=%s\nStartupWMClass=agenthub-desktop\n' "$old_entry_home/.local/share/agenthub/agenthub-desktop" \
	>"$old_entry_home/.local/share/applications/agenthub.desktop"
checks=$((checks + 1))
PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$old_entry_home" sh "$installer" --uninstall >"$work/old-entry.txt" 2>&1 || fail "old-entry: failed: $(cat "$work/old-entry.txt")"
checks=$((checks + 1))
! exists_path "$old_entry_home/.local/share/applications/agenthub.desktop" || fail "old-entry: the unquoted entry was left"

echo "== a marker that is not the installer's line is left, dry run or not =="
odd_home="$work/odd-home"
mkdir -p "$odd_home"
# shellcheck disable=SC2016 # literal startup-file lines
printf 'alias keep=1\n#  # added by the AgentHub installer (old note)\nexport PATH="$HOME/bin:$PATH"' >"$odd_home/.bashrc"
cp "$odd_home/.bashrc" "$work/odd-bashrc.before"
for odd_mode in --dry-run ""; do
	checks=$((checks + 1))
	# shellcheck disable=SC2086 # the empty mode is meant to vanish
	PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
		sandboxed "$odd_home" sh "$installer" --uninstall $odd_mode >"$work/odd.txt" 2>&1 || fail "odd: failed: $(cat "$work/odd.txt")"
	contains "odd$odd_mode" "$work/odd.txt" "not as the line this script writes; left it as it is"
	lacks "odd$odd_mode" "$work/odd.txt" "remove the Agent Hallway PATH lines"
	lacks "odd$odd_mode" "$work/odd.txt" "removed the Agent Hallway PATH lines"
	checks=$((checks + 1))
	cmp -s "$odd_home/.bashrc" "$work/odd-bashrc.before" || fail "odd$odd_mode: .bashrc was rewritten"
done

echo "== a service that will not come down stops the uninstall =="
refuse_home="$work/refuse-home"
tree_at "$refuse_home/.local/share/agenthub" "$work/refuse-ah.log" "" 1
make_unit "$refuse_home" linux "$refuse_home/.local/share/agenthub/agenthub-node"
checks=$((checks + 1))
if PATH="$linux_shim:$bare_path" SHELL=/bin/bash \
	sandboxed "$refuse_home" sh "$installer" --uninstall >"$work/refuse.txt" 2>&1; then
	fail "refuse: a failed service uninstall was carried past"
fi
contains refuse "$work/refuse.txt" "nothing else was removed"
checks=$((checks + 1))
[ -x "$refuse_home/.local/share/agenthub/ah" ] || fail "refuse: the install was deleted under a registered service"

echo "== --uninstall on macOS finds the app in either Applications =="
# /Applications is where install goes when it can write there, ~/Applications
# otherwise; an account made admin since the install changes which one that is.
mac_home="$work/mac-home"
mac_apps="$work/mac-Applications"
mac_bundle "$mac_apps/agenthub-desktop.app" "$work/mac-ah.log"
mac_bundle "$mac_home/Applications/agenthub-desktop.app" "$work/mac-home-ah.log"
mkdir -p "$mac_home/.local/bin" "$mac_home/Library/Caches/com.wails.agenthub-desktop" "$mac_home/Library/Preferences"
touch "$mac_home/Library/Preferences/com.wails.agenthub-desktop.plist"
ln -s "$mac_home/Applications/agenthub-desktop.app/Contents/MacOS/ah" "$mac_home/.local/bin/ah"
make_unit "$mac_home" darwin "$mac_home/Applications/agenthub-desktop.app/Contents/MacOS/agenthub-node"
# shellcheck disable=SC2016 # the literal lines the installer writes
printf 'alias keep=1\n\n# added by the AgentHub installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >"$mac_home/.zshrc"
printf 'alias keep=1\n' >"$work/mac-zshrc.after"
cp "$mac_home/.zshrc" "$work/mac-zshrc.before"
mac_un() { # mac_un <output file> [args...]
	local out=$1
	shift
	PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh \
		sandboxed "$mac_home" env AGENTHALLWAY_APPLICATIONS="$mac_apps" sh "$installer" --uninstall "$@" >"$out" 2>&1
}
checks=$((checks + 1))
mac_un "$work/mac-dry.txt" --dry-run || fail "mac-dry: failed: $(cat "$work/mac-dry.txt")"
commands_only "$work/mac-dry.txt" "$work/mac-dry.cmds"
contains mac-dry "$work/mac-dry.cmds" "service uninstall"
contains mac-dry "$work/mac-dry.cmds" "rm -rf $mac_apps/agenthub-desktop.app"
contains mac-dry "$work/mac-dry.cmds" "rm -rf $mac_home/Applications/agenthub-desktop.app"
contains mac-dry "$work/mac-dry.cmds" "rm -f $mac_home/.local/bin/ah"
contains mac-dry "$work/mac-dry.cmds" "rm -rf $mac_home/Library/Caches/com.wails.agenthub-desktop"
contains mac-dry "$work/mac-dry.txt" "+ remove the Agent Hallway PATH lines from $mac_home/.zshrc"
contains mac-dry "$work/mac-dry.txt" "nothing was removed"
lacks mac-dry "$work/mac-dry.txt" "removed $mac_home"
lacks mac-dry "$work/mac-dry.txt" "done. Agent Hallway is uninstalled."
lacks mac-dry "$work/mac-dry.cmds" "sudo"
for kept in "$mac_apps/agenthub-desktop.app" "$mac_home/.local/bin/ah" "$mac_home/Library/Caches/com.wails.agenthub-desktop"; do
	checks=$((checks + 1))
	exists_path "$kept" || fail "mac-dry: a dry run removed $kept"
done
checks=$((checks + 1))
cmp -s "$mac_home/.zshrc" "$work/mac-zshrc.before" || fail "mac-dry: a dry run rewrote .zshrc"
# Reading the registration is what a dry run is for; taking it down is not.
: >>"$work/mac-ah.log"
: >>"$work/mac-home-ah.log"
lacks mac-dry "$work/mac-ah.log" "service uninstall"
lacks mac-dry "$work/mac-home-ah.log" "service uninstall"
checks=$((checks + 1))
mac_un "$work/mac.txt" || fail "mac: failed: $(cat "$work/mac.txt")"
for gone in "$mac_apps/agenthub-desktop.app" "$mac_home/Applications/agenthub-desktop.app" "$mac_home/.local/bin/ah" \
	"$mac_home/Library/Caches/com.wails.agenthub-desktop" "$mac_home/Library/Preferences/com.wails.agenthub-desktop.plist"; do
	checks=$((checks + 1))
	! exists_path "$gone" || fail "mac: $gone is still there"
done
checks=$((checks + 1))
cmp -s "$mac_home/.zshrc" "$work/mac-zshrc.after" || fail "mac: .zshrc is not the owner's lines alone: $(cat "$mac_home/.zshrc")"

echo "== a --prefix uninstall touches nothing outside the prefix =="
# The real install is on this HOME — its service, its data, its PATH line, its
# caches, an ah on PATH — and the run being made is for a --prefix install.
real_home="$work/real-home"
real_pfx="$work/real-pfx"
mac_bundle "$real_pfx/agenthub-desktop.app" "$work/real-pfx-ah.log"
mkdir -p "$real_pfx/bin" "$real_home/Library/Caches/com.wails.agenthub-desktop" \
	"$real_home/Library/Application Support/agenthub" "$real_home/Library/Logs/agenthub" "$work/real-shim"
touch "$real_pfx/.agenthub-install"
ln -s "$real_pfx/agenthub-desktop.app/Contents/MacOS/ah" "$real_pfx/bin/ah"
echo key >"$real_home/Library/Application Support/agenthub/node.key"
make_unit "$real_home" darwin "/Applications/agenthub-desktop.app/Contents/MacOS/agenthub-node"
cp "$work/mac-zshrc.before" "$real_home/.zshrc"
uninstall_ah_script "$work/real-shim/ah" "$work/real-path-ah.log" "" 0
checks=$((checks + 1))
PATH="$work/real-shim:$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh \
	sandboxed "$real_home" sh "$installer" --uninstall --purge --prefix "$real_pfx" >"$work/real-pfx.txt" 2>&1 ||
	fail "real-pfx: failed: $(cat "$work/real-pfx.txt")"
for gone in "$real_pfx/agenthub-desktop.app" "$real_pfx/bin/ah" "$real_pfx/.agenthub-install"; do
	checks=$((checks + 1))
	! exists_path "$gone" || fail "real-pfx: $gone is still there"
done
for kept in "Library/Application Support/agenthub/node.key" "Library/Logs/agenthub" \
	"Library/Caches/com.wails.agenthub-desktop" "Library/LaunchAgents/local.agenthub.node.plist"; do
	checks=$((checks + 1))
	exists_path "$real_home/$kept" || fail "real-pfx: the real install's $kept was removed"
done
checks=$((checks + 1))
cmp -s "$real_home/.zshrc" "$work/mac-zshrc.before" || fail "real-pfx: the real .zshrc was rewritten"
checks=$((checks + 1))
[ ! -e "$work/real-path-ah.log" ] || fail "real-pfx: the ah on PATH was run: $(cat "$work/real-path-ah.log")"

echo "== --uninstall refuses the flags that do not go with it =="
checks=$((checks + 1))
if sh "$installer" --purge >"$work/purge-alone.txt" 2>&1; then fail "--purge alone was accepted"; fi
contains purge-alone "$work/purge-alone.txt" "--purge only goes with --uninstall"
checks=$((checks + 1))
if sh "$installer" --uninstall --version v0.1.0 >"$work/un-version.txt" 2>&1; then fail "--uninstall --version was accepted"; fi
contains un-version "$work/un-version.txt" "do not go with it"

# ---- a running app on a macOS upgrade --------------------------------------

# A real macOS install from a .dmg, on any machine: hdiutil, ditto and xattr
# are shims, and so are the two things quit_running_app asks — osascript, and
# pgrep for whether the app is still there. What is real is the rm -rf of the
# old bundle, which is why every run is a --prefix install into the work
# directory, with a HOME of its own, and why a dry run of the same command has
# to show that rm naming the prefix — and nothing under /Applications — before
# any real run is made. A faked uname does not fake the disk.
#
# The case that matters is issue #211: a Wails app answers every quit request
# with "cancel" (-128) and then quits on its own a moment later, and that
# answer used to end the install under set -e with a raw AppleScript line.
quit_shim="$work/quit-shim"
mkdir -p "$quit_shim"
# pgrep answers only for the prefix's app and says "not running" for anything
# else, so no pattern this suite does not control can match a real process.
# Its first call is quit_running_app's "is it running?"; every call after that
# is one turn of the wait loop, and QUIT_RUNNING_FOR says how many of those
# still find it ("forever" for an app that never goes).
cat >"$quit_shim/pgrep" <<'EOF'
#!/bin/sh
echo "$*" >>"$QUIT_LOG.pgrep"
case "$*" in
*"$QUIT_PREFIX/${QUIT_APP:-agenthub-desktop}.app/Contents/MacOS/desktop"*) ;;
*) exit 1 ;;
esac
calls=$(($(cat "$QUIT_LOG.count" 2>/dev/null || echo 0) + 1))
echo "$calls" >"$QUIT_LOG.count"
[ "$calls" -eq 1 ] && exit 0
[ "$QUIT_RUNNING_FOR" = forever ] && exit 0
[ "$calls" -le $((QUIT_RUNNING_FOR + 1)) ] && exit 0
exit 1
EOF
cat >"$quit_shim/osascript" <<'EOF'
#!/bin/sh
echo "$*" >>"$QUIT_LOG.osascript"
if [ "$QUIT_OSASCRIPT" = refuse ]; then
	# What macOS printed on the machine in issue #211, localised as it was.
	echo "0:27: execution error: agenthub-desktop發生錯誤：使用者取消操作。 (-128)" >&2
	exit 1
fi
EOF
# hdiutil attach "mounts" a new bundle, marked new, at the mount point.
cat >"$quit_shim/hdiutil" <<'EOF'
#!/bin/sh
echo "$*" >>"$QUIT_LOG.hdiutil"
[ "$1" = attach ] || exit 0
while [ "$#" -gt 1 ]; do
	[ "$1" = -mountpoint ] && mount_point=$2
	shift
done
app=${QUIT_APP:-agenthub-desktop}
mkdir -p "$mount_point/$app.app/Contents/MacOS"
echo new >"$mount_point/$app.app/Contents/MacOS/desktop"
printf '#!/bin/sh\necho "ah (fake, new)"\n' >"$mount_point/$app.app/Contents/MacOS/ah"
chmod +x "$mount_point/$app.app/Contents/MacOS/ah"
EOF
# ditto writes only into the prefix; anywhere else is a test that has escaped.
cat >"$quit_shim/ditto" <<'EOF'
#!/bin/sh
case "$2" in
"$QUIT_PREFIX"/*) cp -R "$1" "$2" ;;
*) echo "ditto shim: refusing to write $2 outside $QUIT_PREFIX" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$quit_shim/xattr"
# The wait loop sleeps a second a turn; the shim keeps ten turns from costing
# ten seconds. pgrep's count, not the clock, is what the cases turn on.
printf '#!/bin/sh\nexit 0\n' >"$quit_shim/sleep"
chmod +x "$quit_shim"/*
quit_dmg_dir="$work/quit-dmg"
mkdir -p "$quit_dmg_dir"
echo "not really a disk image" >"$quit_dmg_dir/agenthub-desktop_v0.1.0_darwin_universal.dmg"
echo "not really a disk image either" >"$quit_dmg_dir/agenthallway-desktop_v0.2.0_darwin_universal.dmg"
(
	cd "$quit_dmg_dir"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum agenthub-desktop_v0.1.0_darwin_universal.dmg agenthallway-desktop_v0.2.0_darwin_universal.dmg >SHA256SUMS
	else
		shasum -a 256 agenthub-desktop_v0.1.0_darwin_universal.dmg agenthallway-desktop_v0.2.0_darwin_universal.dmg >SHA256SUMS
	fi
)
quit_darwin=$(fake_uname Darwin arm64)

# quit_case puts the previous version's bundle, marked old, in a fresh prefix
# and runs a real upgrade over it. Its status is the installer's. QUIT_APP
# names the app (the pre-rename one, from the v0.1.0 image, unless a case
# says agenthallway-desktop, from the v0.2.0 one).
quit_case() { # quit_case <name> <ok|refuse> <turns still running|forever> [args...]
	local name=$1 osascript_mode=$2 running_for=$3 app=${QUIT_APP:-agenthub-desktop} image
	shift 3
	if [ "$app" = agenthub-desktop ]; then
		image=agenthub-desktop_v0.1.0_darwin_universal.dmg
	else
		image=agenthallway-desktop_v0.2.0_darwin_universal.dmg
	fi
	QUIT_PFX="$work/quit-$name"
	QUIT_OUT="$work/quit-$name.txt"
	mkdir -p "$QUIT_PFX/$app.app/Contents/MacOS" "$work/quit-$name-home"
	touch "$QUIT_PFX/.agenthub-install"
	echo old >"$QUIT_PFX/$app.app/Contents/MacOS/desktop"
	rm -f "$work/quit-$name.log".*
	PATH="$quit_shim:$quit_darwin:$bare_path" SHELL=/bin/zsh \
		QUIT_LOG="$work/quit-$name.log" QUIT_PREFIX="$QUIT_PFX" QUIT_APP="$app" \
		QUIT_OSASCRIPT="$osascript_mode" QUIT_RUNNING_FOR="$running_for" \
		sandboxed "$work/quit-$name-home" sh "$installer" \
		--from "$quit_dmg_dir/$image" \
		--prefix "$QUIT_PFX" --no-service --no-open --no-modify-path --no-skill "$@" >"$QUIT_OUT" 2>&1
}

echo "== a running app: the dry run stays inside the prefix =="
checks=$((checks + 1))
quit_safe=1
if ! quit_case dry refuse forever --dry-run; then
	fail "quit-dry: the dry run failed: $(cat "$QUIT_OUT")"
	quit_safe=0
fi
commands_only "$QUIT_OUT" "$work/quit-dry.cmds"
checks=$((checks + 1))
if ! grep -qxF -- "+ rm -rf $QUIT_PFX/agenthub-desktop.app" "$work/quit-dry.cmds"; then
	fail "quit-dry: the old bundle's rm -rf is not the prefix's: $(grep -F 'rm -rf' "$work/quit-dry.cmds")"
	quit_safe=0
fi
checks=$((checks + 1))
if grep -qF "/Applications" "$work/quit-dry.cmds"; then
	fail "quit-dry: a command names /Applications: $(grep -F /Applications "$work/quit-dry.cmds")"
	quit_safe=0
fi
contains quit-dry "$work/quit-dry.cmds" "osascript -e 'quit app \"agenthub-desktop\"'"
checks=$((checks + 1))
[ ! -e "$work/quit-dry.log.osascript" ] || fail "quit-dry: a dry run ran osascript"

if [ "$quit_safe" -eq 1 ]; then
	echo "== a quit macOS calls cancelled, then the app quits: the upgrade completes =="
	checks=$((checks + 1))
	quit_case late refuse 2 || fail "quit-late: the upgrade failed: $(cat "$QUIT_OUT")"
	contains quit-late "$QUIT_OUT" "agenthub-desktop is running; asking it to quit"
	contains quit-late "$QUIT_OUT" "agenthub-desktop quit"
	contains quit-late "$QUIT_OUT" "installed $QUIT_PFX/agenthub-desktop.app"
	contains quit-late "$QUIT_OUT" "done. AgentHub"
	# -128 is the normal answer to a quit that then happens; it is not news.
	lacks quit-late "$QUIT_OUT" "execution error"
	contains quit-late "$QUIT_PFX/agenthub-desktop.app/Contents/MacOS/desktop" "new"
	contains quit-late "$work/quit-late.log.osascript" "-e quit app \"agenthub-desktop\""
	# Asked once to see it running, then three turns: two still there, one gone.
	checks=$((checks + 1))
	[ "$(cat "$work/quit-late.log.count")" = 4 ] ||
		fail "quit-late: pgrep was asked $(cat "$work/quit-late.log.count") times, not 4"

	echo "== a quit that is cancelled and never happens: our message, the old app kept =="
	checks=$((checks + 1))
	if quit_case never refuse forever; then
		fail "quit-never: the upgrade went on with the app still running"
	fi
	contains quit-never "$QUIT_OUT" "install.sh: agenthub-desktop is still running after 10 seconds"
	contains quit-never "$QUIT_OUT" "Quit it yourself (right-click its Dock icon, Quit) and run this again."
	contains quit-never "$QUIT_OUT" "(macOS answered the quit request with: 0:27: execution error: agenthub-desktop發生錯誤：使用者取消操作。 (-128))"
	# The AppleScript line appears once, inside our message, and not ahead of it.
	checks=$((checks + 1))
	[ "$(grep -c "execution error" "$QUIT_OUT")" = 1 ] ||
		fail "quit-never: the AppleScript reply appears $(grep -c "execution error" "$QUIT_OUT") times, not once: $(cat "$QUIT_OUT")"
	lacks quit-never "$QUIT_OUT" "installed $QUIT_PFX/agenthub-desktop.app"
	checks=$((checks + 1))
	[ "$(cat "$QUIT_PFX/agenthub-desktop.app/Contents/MacOS/desktop" 2>/dev/null)" = old ] ||
		fail "quit-never: the running app's bundle was removed or replaced"
	# The whole loop ran: one "is it running?" and ten turns.
	checks=$((checks + 1))
	[ "$(cat "$work/quit-never.log.count")" = 11 ] ||
		fail "quit-never: pgrep was asked $(cat "$work/quit-never.log.count") times, not 11"

	echo "== a quit macOS accepts: the upgrade completes as before =="
	checks=$((checks + 1))
	quit_case ok ok 0 || fail "quit-ok: the upgrade failed: $(cat "$QUIT_OUT")"
	contains quit-ok "$QUIT_OUT" "agenthub-desktop quit"
	contains quit-ok "$QUIT_OUT" "done. AgentHub"
	contains quit-ok "$QUIT_PFX/agenthub-desktop.app/Contents/MacOS/desktop" "new"
	contains quit-ok "$work/quit-ok.log.osascript" "-e quit app \"agenthub-desktop\""

	# A QUIT_APP_PATH left in the owner's environment must not point the
	# running-app check at some other bundle: the upgrade would then skip the
	# quit and replace a running app's files.
	QUIT_APP_PATH=/nowhere/agenthub-desktop.app quit_case stray ok 0 ||
		fail "quit-stray: the upgrade failed: $(cat "$QUIT_OUT")"
	contains quit-stray "$QUIT_OUT" "agenthub-desktop quit"
	contains quit-stray "$work/quit-stray.log.osascript" "-e quit app \"agenthub-desktop\""

	echo "== the current app: a quit macOS calls cancelled, then the app quits =="
	checks=$((checks + 1))
	QUIT_APP=agenthallway-desktop quit_case current refuse 2 || fail "quit-current: the upgrade failed: $(cat "$QUIT_OUT")"
	contains quit-current "$QUIT_OUT" "agenthallway-desktop is running; asking it to quit"
	contains quit-current "$QUIT_OUT" "agenthallway-desktop quit"
	contains quit-current "$QUIT_OUT" "installed $QUIT_PFX/agenthallway-desktop.app"
	contains quit-current "$QUIT_OUT" "done. Agent Hallway"
	contains quit-current "$QUIT_PFX/agenthallway-desktop.app/Contents/MacOS/desktop" "new"
	contains quit-current "$work/quit-current.log.osascript" "-e quit app \"agenthallway-desktop\""
	checks=$((checks + 1))
	[ ! -e "$QUIT_PFX/.agenthub-install" ] || fail "quit-current: the prefix's pre-rename marker was not retired"

	echo "== a quit macOS accepts but the app stays: our message, no reply to quote =="
	checks=$((checks + 1))
	if quit_case stays ok forever; then
		fail "quit-stays: the upgrade went on with the app still running"
	fi
	contains quit-stays "$QUIT_OUT" "Quit it yourself (right-click its Dock icon, Quit) and run this again."
	lacks quit-stays "$QUIT_OUT" "macOS answered"
	checks=$((checks + 1))
	[ "$(cat "$QUIT_PFX/agenthub-desktop.app/Contents/MacOS/desktop" 2>/dev/null)" = old ] ||
		fail "quit-stays: the running app's bundle was removed or replaced"
else
	echo "  skipped the real quit cases: the dry run did not stay inside the prefix" >&2
fi

# ---- the Claude Code skill ---------------------------------------------------

# The skill is what tells an agent on this machine that `ah` exists. It travels
# inside the release asset, so the digest check covers it; the dry runs assert
# it is copied from what was unpacked, and the real installs below assert what
# lands, what is replaced, and what is never touched.
echo "== a dry run prints the skill install and writes nothing =="
# Without --prefix, into a HOME of the suite's own: a default install is the
# one that writes the skill.
skill_dry_home="$work/skill-dry-home"
mkdir -p "$skill_dry_home"
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
DRY_HOME="$skill_dry_home" dry_run Linux x86_64 "$work/skill-dry-linux.txt" --version v0.1.0 --no-service
unset LDCONFIG_SHIM
commands_only "$work/skill-dry-linux.txt" "$work/skill-dry-linux.cmds"
contains skill-dry "$work/skill-dry-linux.cmds" "cp -R $skill_dry_home/.local/share/agenthub/skills/agenthub-watch"
contains skill-dry "$work/skill-dry-linux.cmds" "mv "
contains skill-dry "$work/skill-dry-linux.cmds" "$CLAUDE_CONFIG_DIR/skills/agenthub-watch"
contains skill-dry "$work/skill-dry-linux.txt" "installed the Claude Code skill $CLAUDE_CONFIG_DIR/skills/agenthub-watch"
contains skill-dry "$work/skill-dry-linux.txt" "skill: $CLAUDE_CONFIG_DIR/skills/agenthub-watch (Claude Code sessions started from now on load it"
DRY_HOME="$skill_dry_home" dry_run Darwin arm64 "$work/skill-dry-mac.txt" --version v0.1.0 --no-service --no-open
commands_only "$work/skill-dry-mac.txt" "$work/skill-dry-mac.cmds"
contains skill-dry "$work/skill-dry-mac.cmds" "/mnt/.skills/agenthub-watch"
contains skill-dry "$work/skill-dry-mac.cmds" "$CLAUDE_CONFIG_DIR/skills/agenthub-watch"
# The skill is copied out of the image before it is detached.
checks=$((checks + 1))
if [ "$(grep -n '/mnt/.skills/agenthub-watch' "$work/skill-dry-mac.txt" | cut -d: -f1 | head -n1)" -gt \
	"$(grep -n 'hdiutil detach' "$work/skill-dry-mac.txt" | cut -d: -f1 | head -n1)" ]; then
	fail "skill-dry: the skill is copied from the image after it is detached"
fi
# Nothing is fetched on its own: a skill from raw.githubusercontent would be a
# file no SHA256SUMS ever vouched for.
lacks skill-dry "$work/skill-dry-linux.txt" "raw.githubusercontent.com/SheldonChangL/agenthub/main/.claude"
lacks skill-dry "$work/skill-dry-mac.txt" "raw.githubusercontent.com/SheldonChangL/agenthub/main/.claude"
checks=$((checks + 1))
! exists_path "$CLAUDE_CONFIG_DIR/skills/agenthub-watch" || fail "skill-dry: a dry run installed the skill"
DRY_HOME="$skill_dry_home" dry_run Darwin arm64 "$work/skill-dry-no.txt" --version v0.1.0 --no-service --no-open --no-skill
commands_only "$work/skill-dry-no.txt" "$work/skill-dry-no.cmds"
lacks skill-dry-no "$work/skill-dry-no.cmds" "skills/agenthub-watch"
contains skill-dry-no "$work/skill-dry-no.txt" "skipped the Claude Code skill (--no-skill)"
# --prefix writes nothing outside the prefix, and ~/.claude is outside it.
commands_only "$work/linux.txt" "$work/linux.cmds"
lacks skill-prefix "$work/linux.cmds" "$CLAUDE_CONFIG_DIR"
lacks skill-prefix "$work/darwin.cmds" "$CLAUDE_CONFIG_DIR"
contains skill-prefix "$work/linux.txt" "skipped the Claude Code skill: a --prefix install writes nothing outside $work/pfx"

skill_stage="$work/stage-skill/agenthub-desktop_v0.1.0_linux_amd64"
mkdir -p "$skill_stage/skills/agenthub-watch"
for binary in ah agenthub-node agenthub-mcp agenthub-desktop; do
	printf '#!/bin/sh\necho "%s v0.1.0 (fake)"\n' "$binary" >"$skill_stage/$binary"
	chmod +x "$skill_stage/$binary"
done
skill_md="$repository/.claude/skills/agenthallway-watch/SKILL.md"
cp "$skill_md" "$skill_stage/skills/agenthub-watch/"
skilled="$work/skilled"
mkdir -p "$skilled"
tar -C "$work/stage-skill" -czf "$skilled/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" \
	agenthub-desktop_v0.1.0_linux_amd64
(
	cd "$skilled"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum agenthub-desktop_v0.1.0_linux_amd64.tar.gz >SHA256SUMS
	else
		shasum -a 256 agenthub-desktop_v0.1.0_linux_amd64.tar.gz >SHA256SUMS
	fi
)
skill_home="$work/skill-home"
mkdir -p "$skill_home"
skill_run() { # skill_run <output file> <claude config dir> [args...]
	local out=$1 cfg=$2
	shift 2
	PATH="$linux_shim:$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$cfg" \
		sandboxed "$skill_home" sh "$installer" "$@" >"$out" 2>&1
}
skill_install() { # skill_install <output file> <claude config dir> [archive] [args...]
	local out=$1 cfg=$2 archive=${3:-$skilled/agenthub-desktop_v0.1.0_linux_amd64.tar.gz}
	shift 3 || shift $#
	skill_run "$out" "$cfg" --from "$archive" --no-service --no-modify-path "$@"
}

echo "== a fresh install puts the skill where Claude Code reads it =="
ours="$work/skill-ours"
checks=$((checks + 1))
skill_install "$work/skill-fresh.txt" "$ours" || fail "skill-fresh: the install failed: $(cat "$work/skill-fresh.txt")"
contains skill-fresh "$work/skill-fresh.txt" "verified agenthub-desktop_v0.1.0_linux_amd64.tar.gz against SHA256SUMS"
contains skill-fresh "$work/skill-fresh.txt" "installed the Claude Code skill $ours/skills/agenthub-watch"
contains skill-fresh "$work/skill-fresh.txt" "skill: $ours/skills/agenthub-watch (Claude Code sessions started from now on load it"
checks=$((checks + 1))
cmp -s "$ours/skills/agenthub-watch/SKILL.md" "$skill_md" || fail "skill-fresh: SKILL.md is not the one in the archive"
checks=$((checks + 1))
[ -f "$ours/skills/agenthub-watch/.agenthub-install" ] || fail "skill-fresh: the installed skill carries no marker"

echo "== an upgrade replaces the copy it installed =="
echo "stale" >"$ours/skills/agenthub-watch/stale.txt"
echo "an old version" >"$ours/skills/agenthub-watch/SKILL.md"
checks=$((checks + 1))
skill_install "$work/skill-upgrade.txt" "$ours" || fail "skill-upgrade: the install failed: $(cat "$work/skill-upgrade.txt")"
contains skill-upgrade "$work/skill-upgrade.txt" "installed the Claude Code skill $ours/skills/agenthub-watch"
checks=$((checks + 1))
cmp -s "$ours/skills/agenthub-watch/SKILL.md" "$skill_md" || fail "skill-upgrade: SKILL.md was not replaced"
checks=$((checks + 1))
[ ! -e "$ours/skills/agenthub-watch/stale.txt" ] || fail "skill-upgrade: a file of the old copy survived"
checks=$((checks + 1))
[ -f "$ours/skills/agenthub-watch/.agenthub-install" ] || fail "skill-upgrade: the upgraded skill carries no marker"

echo "== a skill that is not ours is left alone =="
# The owner's own arrangement: skills kept elsewhere and linked in, with the
# same relative link this machine's owner uses.
linked="$work/skill-linked"
mkdir -p "$linked/skills" "$work/own-skills/agenthub-watch"
echo "mine" >"$work/own-skills/agenthub-watch/SKILL.md"
ln -s ../../own-skills/agenthub-watch "$linked/skills/agenthub-watch"
checks=$((checks + 1))
skill_install "$work/skill-linked.txt" "$linked" || fail "skill-linked: the install failed: $(cat "$work/skill-linked.txt")"
contains skill-linked "$work/skill-linked.txt" "left $linked/skills/agenthub-watch alone"
checks=$((checks + 1))
[ -L "$linked/skills/agenthub-watch" ] || fail "skill-linked: the owner's link was replaced"
checks=$((checks + 1))
[ "$(cat "$work/own-skills/agenthub-watch/SKILL.md")" = "mine" ] || fail "skill-linked: the owner's skill was written through the link"
checks=$((checks + 1))
[ ! -e "$work/own-skills/agenthub-watch/.agenthub-install" ] || fail "skill-linked: a marker was written through the link"
# A real directory without the marker is the owner's too.
copied="$work/skill-copied"
mkdir -p "$copied/skills/agenthub-watch"
echo "mine" >"$copied/skills/agenthub-watch/SKILL.md"
checks=$((checks + 1))
skill_install "$work/skill-copied.txt" "$copied" || fail "skill-copied: the install failed: $(cat "$work/skill-copied.txt")"
contains skill-copied "$work/skill-copied.txt" "left $copied/skills/agenthub-watch alone"
checks=$((checks + 1))
[ "$(cat "$copied/skills/agenthub-watch/SKILL.md")" = "mine" ] || fail "skill-copied: the owner's copy was replaced"

echo "== --no-skill installs everything but the skill =="
declined="$work/skill-declined"
checks=$((checks + 1))
skill_install "$work/skill-no.txt" "$declined" "" --no-skill || fail "skill-no: the install failed: $(cat "$work/skill-no.txt")"
contains skill-no "$work/skill-no.txt" "skipped the Claude Code skill (--no-skill)"
contains skill-no "$work/skill-no.txt" "skill: not installed (--no-skill)"
checks=$((checks + 1))
! exists_path "$declined/skills/agenthub-watch" || fail "skill-no: --no-skill installed the skill"
checks=$((checks + 1))
[ -x "$skill_home/.local/share/agenthub/ah" ] || fail "skill-no: --no-skill left no ah"

echo "== a release without the skill warns and installs the rest =="
older="$work/skill-older"
checks=$((checks + 1))
skill_install "$work/skill-old.txt" "$older" "$good/agenthub-desktop_v0.1.0_linux_amd64.tar.gz" ||
	fail "skill-old: an archive without the skill failed the install: $(cat "$work/skill-old.txt")"
contains skill-old "$work/skill-old.txt" "warning: this release does not carry the agenthub-watch skill"
contains skill-old "$work/skill-old.txt" "skill: not installed (this release does not carry it)"
contains skill-old "$work/skill-old.txt" "done. AgentHub"
checks=$((checks + 1))
! exists_path "$older/skills/agenthub-watch" || fail "skill-old: a skill appeared from an archive without one"

echo "== --uninstall removes only the skill it installed =="
checks=$((checks + 1))
skill_run "$work/skill-un-keep.txt" "$ours" --uninstall --no-skill || fail "skill-un-keep: failed: $(cat "$work/skill-un-keep.txt")"
checks=$((checks + 1))
[ -f "$ours/skills/agenthub-watch/SKILL.md" ] || fail "skill-un-keep: --uninstall --no-skill removed the skill"
checks=$((checks + 1))
skill_run "$work/skill-un.txt" "$ours" --uninstall || fail "skill-un: failed: $(cat "$work/skill-un.txt")"
contains skill-un "$work/skill-un.txt" "removed $ours/skills/agenthub-watch"
checks=$((checks + 1))
! exists_path "$ours/skills/agenthub-watch" || fail "skill-un: the installed skill is still there"
checks=$((checks + 1))
skill_run "$work/skill-un-linked.txt" "$linked" --uninstall || fail "skill-un-linked: failed: $(cat "$work/skill-un-linked.txt")"
contains skill-un-linked "$work/skill-un-linked.txt" "left $linked/skills/agenthub-watch alone"
checks=$((checks + 1))
[ -L "$linked/skills/agenthub-watch" ] || fail "skill-un-linked: --uninstall removed the owner's link"
[ -f "$work/own-skills/agenthub-watch/SKILL.md" ] || fail "skill-un-linked: --uninstall removed the owner's skill behind the link"
checks=$((checks + 1))
skill_run "$work/skill-un-copied.txt" "$copied" --uninstall || fail "skill-un-copied: failed: $(cat "$work/skill-un-copied.txt")"
checks=$((checks + 1))
[ -f "$copied/skills/agenthub-watch/SKILL.md" ] || fail "skill-un-copied: --uninstall removed the owner's copy"

# ---- the current era, and upgrades from the pre-rename one -----------------
#
# Everything above runs a pre-rename tag (v0.1.0) or an uninstall. From here
# on: what v0.2.0 installs, what an upgrade from v0.1.11 leaves behind and
# removes, and the two eras' installs side by side. Every case that removes
# anything first runs the same command with --dry-run and requires each
# absolute path it would touch to be inside the work directory; the real run is
# skipped when it is not.

# without_work prints a transcript with the work directory's path replaced:
# that path holds "agenthallway" (it is a mktemp of agenthallway-install-test),
# which would otherwise be found by every "no current name here" check.
without_work() { # without_work <transcript> <destination>
	sed "s|$work|WORK|g" "$1" >"$2"
}

# assert_confined fails when a dry run's commands name an absolute path
# outside the work directory: that is what the real run of the same case
# would touch.
assert_confined() { # assert_confined <label> <transcript>
	local bad
	bad=$(grep '^+ ' "$2" | tr ' ' '\n' | tr -d "'\"" | grep '^/' | grep -v -e "^$work/" || true)
	checks=$((checks + 1))
	if [ -n "$bad" ]; then
		fail "$1: the dry run names paths outside the work directory, so the real run was not made: $bad"
		return 1
	fi
	return 0
}

# quote_for_test spells an argument the way install.sh's quote() prints it in
# a dry-run transcript: bare when it is an ordinary word, single-quoted
# otherwise (a path with a space in it, as under Application Support).
quote_for_test() { # quote_for_test <argument>
	case "$1" in
	"" | *[!A-Za-z0-9._/:=@+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
	*) printf '%s' "$1" ;;
	esac
}

# path_state prints a path (and everything under it) with type, mode, mtime
# and, for a file, its checksum: the same output before and after means the
# run did not touch it.
path_state() { # path_state <path>...
	local top path
	for top in "$@"; do
		if ! exists_path "$top"; then
			echo "absent $top"
			continue
		fi
		find "$top" -print | LC_ALL=C sort | while IFS= read -r path; do
			printf '%s %s' "$path" "$(perl -e '@s = lstat($ARGV[0]); printf "%o %d", $s[2], $s[9]' "$path")"
			if [ -f "$path" ] && [ ! -L "$path" ]; then
				printf ' %s' "$(cksum <"$path")"
			fi
			printf '\n'
		done
	done
}

# sums_beside appends an archive's line to the SHA256SUMS beside it.
sums_beside() { # sums_beside <archive>
	(
		cd "$(dirname "$1")"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "$(basename "$1")"
		else
			shasum -a 256 "$(basename "$1")"
		fi >>SHA256SUMS
	)
}

# current_ah_script writes the ah of a current-era release, as far as
# install.sh and these cases need one. It records what it is asked in
# FAKE_AH_LOG; answers `--json service status` from the unit files under HOME
# the way internal/service Status does (the current registration, else the
# pre-rename one marked Legacy); and changes those files the way the real
# commands do: `service install` retires the pre-rename unit first and then
# writes the current one, starting the node beside this ah, and `service
# uninstall` removes both.
current_ah_script() { # current_ah_script <file>
	cat >"$1" <<'EOF'
#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
echo "$*" >>"${FAKE_AH_LOG:-/dev/null}"
if [ "$(uname -s)" = Darwin ]; then
	current="$HOME/Library/LaunchAgents/local.agenthallway.node.plist"
	legacy="$HOME/Library/LaunchAgents/local.agenthub.node.plist"
else
	current="$HOME/.config/systemd/user/agenthallway-node.service"
	legacy="$HOME/.config/systemd/user/agenthub-node.service"
fi
unit_args() {
	case "$1" in
	*.plist) sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' "$1" | sed 1d ;;
	*) sed -n 's/^ExecStart=//p' "$1" | head -n 1 | tr ' ' '\n' | sed 1d ;;
	esac | sed 's/.*/"&"/' | paste -sd, -
}
case "$*" in
*"--json service status"*)
	if [ -f "$current" ]; then
		also=""
		[ ! -f "$legacy" ] || also=',"LegacyAlsoInstalled":true'
		printf '{"service":{"Installed":true,"Supported":true%s,"Arguments":[%s]}}\n' "$also" "$(unit_args "$current")"
	elif [ -f "$legacy" ]; then
		printf '{"service":{"Installed":true,"Legacy":true,"Supported":true,"Arguments":[%s]}}\n' "$(unit_args "$legacy")"
	else
		printf '{"service":{"Installed":false,"Supported":true}}\n'
	fi
	;;
*"service install"*)
	db=""
	[ "${3:-}" != --db ] || db=$4
	if [ -f "$legacy" ]; then
		rm -f "$legacy"
		echo "stopped and removed the pre-rename service (fake)"
	fi
	mkdir -p "$(dirname "$current")"
	if [ "$(uname -s)" = Darwin ]; then
		{
			printf '<plist version="1.0">\n<dict>\n\t<key>ProgramArguments</key>\n\t<array>\n'
			printf '\t\t<string>%s</string>\n' "$here/agenthallway-node"
			[ -z "$db" ] || printf '\t\t<string>--db</string>\n\t\t<string>%s</string>\n' "$db"
			printf '\t</array>\n</dict>\n</plist>\n'
		} >"$current"
	else
		printf '[Service]\nExecStart=%s%s\n' "$here/agenthallway-node" "${db:+ --db $db}" >"$current"
	fi
	;;
*"service uninstall"*) rm -f "$current" "$legacy" ;;
*"service status"*) echo "background service: registered (fake)" ;;
*) echo "ah (fake, current)" ;;
esac
EOF
	chmod +x "$1"
}

# make_current_unit writes the registration a current ah writes, starting
# <node binary>: the current label or unit name.
make_current_unit() { # make_current_unit <home> <darwin|linux> <node binary> [db]
	local home=$1 os=$2 node=$3 db=${4:-}
	if [ "$os" = darwin ]; then
		mkdir -p "$home/Library/LaunchAgents"
		{
			printf '<plist version="1.0">\n<dict>\n\t<key>ProgramArguments</key>\n\t<array>\n'
			printf '\t\t<string>%s</string>\n' "$node"
			[ -z "$db" ] || printf '\t\t<string>--db</string>\n\t\t<string>%s</string>\n' "$db"
			printf '\t</array>\n</dict>\n</plist>\n'
		} >"$home/Library/LaunchAgents/local.agenthallway.node.plist"
	else
		mkdir -p "$home/.config/systemd/user"
		printf '[Service]\nExecStart=%s%s\n' "$node" "${db:+ --db $db}" \
			>"$home/.config/systemd/user/agenthallway-node.service"
	fi
}

# stage_tree lays out an unpacked release directory of either era: the
# binaries, and the skill under skills/. The current era's ah is
# current_ah_script; the pre-rename one only says what it is.
stage_tree() { # stage_tree <directory> <current|legacy> [no-skill]
	local dir=$1 era=$2 slug app binary
	if [ "$era" = current ]; then
		slug=agenthallway
	else
		slug=agenthub
	fi
	app="$slug-desktop"
	mkdir -p "$dir"
	for binary in "$slug-node" "$slug-mcp" "$app"; do
		printf '#!/bin/sh\necho "%s (fake)"\n' "$binary" >"$dir/$binary"
		chmod +x "$dir/$binary"
	done
	if [ "$era" = current ]; then
		current_ah_script "$dir/ah"
	else
		printf '#!/bin/sh\necho "ah v0.1.11 (fake)"\n' >"$dir/ah"
		chmod +x "$dir/ah"
	fi
	if [ "${3:-}" != no-skill ]; then
		mkdir -p "$dir/skills/$slug-watch"
		printf -- '---\nname: %s-watch\n---\n(fake skill)\n' "$slug" >"$dir/skills/$slug-watch/SKILL.md"
	fi
}

# The two releases, as the release page carries them: a desktop and a command
# line archive per era, and a SHA256SUMS. The webkit40 archives are missing on
# purpose, which is what the fallback cases below turn on.
for release in current:v0.2.0:agenthallway legacy:v0.1.11:agenthub; do
	release_era=${release%%:*}
	release_rest=${release#*:}
	release_tag=${release_rest%%:*}
	release_slug=${release_rest#*:}
	release_dir="$work/rel-$release_era"
	mkdir -p "$release_dir" "$work/stage-$release_era"
	stage_tree "$work/stage-$release_era/${release_slug}-desktop_${release_tag}_linux_amd64" "$release_era"
	tar -C "$work/stage-$release_era" -czf "$release_dir/${release_slug}-desktop_${release_tag}_linux_amd64.tar.gz" \
		"${release_slug}-desktop_${release_tag}_linux_amd64"
	sums_beside "$release_dir/${release_slug}-desktop_${release_tag}_linux_amd64.tar.gz"
	stage_tree "$work/stage-$release_era/${release_slug}_${release_tag}_linux_amd64" "$release_era"
	tar -C "$work/stage-$release_era" -czf "$release_dir/${release_slug}_${release_tag}_linux_amd64.tar.gz" \
		"${release_slug}_${release_tag}_linux_amd64"
	sums_beside "$release_dir/${release_slug}_${release_tag}_linux_amd64.tar.gz"
done
current_tgz="$work/rel-current/agenthallway-desktop_v0.2.0_linux_amd64.tar.gz"
legacy_tgz="$work/rel-legacy/agenthub-desktop_v0.1.11_linux_amd64.tar.gz"

echo "== I1 a pre-rename tag downloads and installs the pre-rename names =="
i1_dry() { # i1_dry <name> <system> <machine> [args...]
	local name=$1
	shift
	dry_run "$1" "$2" "$work/i1-$name.txt" --version v0.1.11 "${@:3}"
	commands_only "$work/i1-$name.txt" "$work/i1-$name.cmds"
	without_work "$work/i1-$name.cmds" "$work/i1-$name.bare"
	lacks "i1-$name" "$work/i1-$name.bare" "agenthallway"
	lacks "i1-$name" "$work/i1-$name.cmds" "sudo"
}
i1_dry darwin Darwin arm64 --no-open
contains i1-darwin "$work/i1-darwin.txt" "agenthub-desktop_v0.1.11_darwin_universal.dmg"
contains i1-darwin "$work/i1-darwin.cmds" "$work/Applications/agenthub-desktop.app"
contains i1-darwin "$work/i1-darwin.cmds" "/mnt/.skills/agenthub-watch"
contains i1-darwin "$work/i1-darwin.cmds" "$CLAUDE_CONFIG_DIR/skills/agenthub-watch"
contains i1-darwin "$work/i1-darwin.txt" "done. AgentHub v0.1.11 is installed:"
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
i1_dry linux Linux x86_64
unset LDCONFIG_SHIM
contains i1-linux "$work/i1-linux.txt" "agenthub-desktop_v0.1.11_linux_amd64.tar.gz"
contains i1-linux "$work/i1-linux.cmds" "$work/dry-home/.local/share/agenthub"
contains i1-linux "$work/i1-linux.cmds" "$work/dry-home/.local/bin/agenthub-desktop"
contains i1-linux "$work/i1-linux.txt" "+ write $work/dry-home/.local/share/applications/agenthub.desktop"
contains i1-linux "$work/i1-linux.cmds" "skill-stage/agenthub-watch/.agenthub-install"
i1_dry cli Linux x86_64 --cli-only
contains i1-cli "$work/i1-cli.txt" "agenthub_v0.1.11_linux_amd64.tar.gz"
contains i1-cli "$work/i1-cli.cmds" "$work/dry-home/.local/bin/agenthub-mcp"
LDCONFIG_SHIM=$(fake_ldconfig 4.0)
i1_dry webkit40 Linux x86_64
unset LDCONFIG_SHIM
contains i1-webkit40 "$work/i1-webkit40.txt" "agenthub-desktop_v0.1.11_linux_amd64_webkit40.tar.gz"
# The fallback for a tag without a webkit40 build, downloaded for real from a
# release page that has none: the plain archive, under the pre-rename name.
i1_home="$work/i1-home"
mkdir -p "$i1_home"
checks=$((checks + 1))
PATH="$(fake_ldconfig 4.0):$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash SB_SERVE="$work/rel-legacy" CLAUDE_CONFIG_DIR="$i1_home/.claude" \
	sandboxed "$i1_home" env AGENTHALLWAY_LDCONFIG_PATHS= sh "$installer" --version v0.1.11 --no-service \
	>"$work/i1-fallback.txt" 2>&1 || fail "i1-fallback: the install failed: $(cat "$work/i1-fallback.txt")"
contains i1-fallback "$work/i1-fallback.txt" "Falling back to agenthub-desktop_v0.1.11_linux_amd64.tar.gz"
contains i1-fallback "$work/i1-fallback.txt" "verified agenthub-desktop_v0.1.11_linux_amd64.tar.gz against SHA256SUMS"
checks=$((checks + 1))
[ -x "$i1_home/.local/share/agenthub/agenthub-node" ] || fail "i1-fallback: no pre-rename tree at $i1_home/.local/share/agenthub"
checks=$((checks + 1))
! exists_path "$i1_home/.local/share/agenthallway" || fail "i1-fallback: a pre-rename tag installed a current tree"

echo "== I2 v0.2.0 installs the new names =="
i2_dry() { # i2_dry <name> <system> <machine> [args...]
	local name=$1
	shift
	dry_run "$1" "$2" "$work/i2-$name.txt" "${@:3}"
	commands_only "$work/i2-$name.txt" "$work/i2-$name.cmds"
	without_work "$work/i2-$name.cmds" "$work/i2-$name.bare"
	lacks "i2-$name" "$work/i2-$name.bare" "agenthub-desktop"
	lacks "i2-$name" "$work/i2-$name.bare" "agenthub_v"
	lacks "i2-$name" "$work/i2-$name.bare" "agenthub-watch"
	lacks "i2-$name" "$work/i2-$name.bare" "share/agenthub/"
	lacks "i2-$name" "$work/i2-$name.cmds" "sudo"
}
# A machine with nothing installed: an Applications of its own, since the
# shared fake one holds a pre-rename app the upgrade would retire.
mkdir -p "$work/i2-Applications"
SB_APPLICATIONS="$work/i2-Applications" i2_dry darwin Darwin arm64 --version v0.2.0 --no-open
contains i2-darwin "$work/i2-darwin.txt" "agenthallway-desktop_v0.2.0_darwin_universal.dmg"
contains i2-darwin "$work/i2-darwin.cmds" "ditto $work/tmp/"
contains i2-darwin "$work/i2-darwin.cmds" "/mnt/agenthallway-desktop.app $work/i2-Applications/agenthallway-desktop.app"
contains i2-darwin "$work/i2-darwin.cmds" "/mnt/.skills/agenthallway-watch"
contains i2-darwin "$work/i2-darwin.cmds" "$CLAUDE_CONFIG_DIR/skills/agenthallway-watch"
contains i2-darwin "$work/i2-darwin.txt" "done. Agent Hallway v0.2.0 is installed:"
contains i2-darwin "$work/i2-darwin.txt" "Open agenthallway-desktop from Applications"
LDCONFIG_SHIM=$(fake_ldconfig 4.1)
i2_dry linux Linux x86_64 --version v0.2.0
unset LDCONFIG_SHIM
contains i2-linux "$work/i2-linux.txt" "agenthallway-desktop_v0.2.0_linux_amd64.tar.gz"
contains i2-linux "$work/i2-linux.cmds" "$work/dry-home/.local/share/agenthallway"
contains i2-linux "$work/i2-linux.cmds" "$work/dry-home/.local/bin/agenthallway-desktop"
contains i2-linux "$work/i2-linux.txt" "+ write $work/dry-home/.local/share/applications/agenthallway.desktop"
contains i2-linux "$work/i2-linux.cmds" "skill-stage/agenthallway-watch/.agenthallway-install"
i2_dry cli Linux x86_64 --version v0.2.0 --cli-only
contains i2-cli "$work/i2-cli.txt" "agenthallway_v0.2.0_linux_amd64.tar.gz"
contains i2-cli "$work/i2-cli.cmds" "$work/dry-home/.local/bin/agenthallway-mcp"
contains i2-cli "$work/i2-cli.cmds" "$work/dry-home/.local/bin/agenthallway-node"
LDCONFIG_SHIM=$(fake_ldconfig 4.0)
i2_dry webkit40 Linux x86_64 --version v0.2.0
unset LDCONFIG_SHIM
contains i2-webkit40 "$work/i2-webkit40.txt" "agenthallway-desktop_v0.2.0_linux_amd64_webkit40.tar.gz"
i2_dry rc Linux x86_64 --version v0.2.0-rc.1 --cli-only
contains i2-rc "$work/i2-rc.txt" "agenthallway_v0.2.0-rc.1_linux_amd64.tar.gz"
i2_dry latest Linux x86_64 --cli-only
contains i2-latest "$work/i2-latest.txt" "agenthallway_vX.Y.Z_linux_amd64.tar.gz"
i2_home="$work/i2-home"
mkdir -p "$i2_home"
checks=$((checks + 1))
PATH="$(fake_ldconfig 4.0):$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash SB_SERVE="$work/rel-current" CLAUDE_CONFIG_DIR="$i2_home/.claude" \
	sandboxed "$i2_home" env AGENTHALLWAY_LDCONFIG_PATHS= sh "$installer" --version v0.2.0 --no-service \
	>"$work/i2-fallback.txt" 2>&1 || fail "i2-fallback: the install failed: $(cat "$work/i2-fallback.txt")"
contains i2-fallback "$work/i2-fallback.txt" "Falling back to agenthallway-desktop_v0.2.0_linux_amd64.tar.gz"
checks=$((checks + 1))
[ -x "$i2_home/.local/share/agenthallway/agenthallway-node" ] || fail "i2-fallback: no current tree at $i2_home/.local/share/agenthallway"

echo "== I3 --from decides the era from the file, and the contents must agree =="
# A file renamed by hand: the name says one era, the binaries are the other's.
# Refused once unpacked or mounted, before anything installed is touched.
for mismatch in current:agenthallway-desktop_v0.2.0_linux_amd64:legacy:agenthub-node \
	legacy:agenthub-desktop_v0.1.11_linux_amd64:current:agenthallway-node; do
	mismatch_name=${mismatch%%:*}
	mismatch_rest=${mismatch#*:}
	mismatch_file=${mismatch_rest%%:*}
	mismatch_rest=${mismatch_rest#*:}
	mismatch_contents=${mismatch_rest%%:*}
	mismatch_found=${mismatch_rest#*:}
	mismatch_dir="$work/i3-$mismatch_name"
	stage_tree "$work/i3-stage-$mismatch_name/$mismatch_file" "$mismatch_contents"
	mkdir -p "$mismatch_dir"
	tar -C "$work/i3-stage-$mismatch_name" -czf "$mismatch_dir/$mismatch_file.tar.gz" "$mismatch_file"
	sums_beside "$mismatch_dir/$mismatch_file.tar.gz"
	i3_home="$work/i3-home-$mismatch_name"
	mkdir -p "$i3_home"
	echo "# the owner's" >"$i3_home/.bashrc"
	i3_before=$(path_state "$i3_home" "$fake_applications")
	checks=$((checks + 1))
	if PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
		sandboxed "$i3_home" sh "$installer" --from "$mismatch_dir/$mismatch_file.tar.gz" \
		>"$work/i3-$mismatch_name.txt" 2>&1; then
		fail "i3-$mismatch_name: an archive whose contents are the other era's was installed"
	fi
	contains "i3-$mismatch_name" "$work/i3-$mismatch_name.txt" "but it contains $mismatch_found"
	contains "i3-$mismatch_name" "$work/i3-$mismatch_name.txt" "nothing was installed"
	checks=$((checks + 1))
	[ "$(path_state "$i3_home" "$fake_applications")" = "$i3_before" ] ||
		fail "i3-$mismatch_name: the refused install changed $i3_home"
done
# The disk image: named for v0.2.0, holding the pre-rename app.
i3_dmg_dir="$work/i3-dmg"
mkdir -p "$i3_dmg_dir" "$work/i3-dmg-contents/agenthub-desktop.app/Contents/MacOS" "$work/i3-mac-home"
echo "not really a disk image" >"$i3_dmg_dir/agenthallway-desktop_v0.2.0_darwin_universal.dmg"
sums_beside "$i3_dmg_dir/agenthallway-desktop_v0.2.0_darwin_universal.dmg"
i3_mac_before=$(path_state "$work/i3-mac-home" "$fake_applications")
checks=$((checks + 1))
if PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh SB_DMG_SOURCE="$work/i3-dmg-contents" \
	sandboxed "$work/i3-mac-home" sh "$installer" --from "$i3_dmg_dir/agenthallway-desktop_v0.2.0_darwin_universal.dmg" \
	>"$work/i3-dmg.txt" 2>&1; then
	fail "i3-dmg: a disk image holding the pre-rename app was installed as v0.2.0"
fi
contains i3-dmg "$work/i3-dmg.txt" "but it contains agenthub-desktop.app"
checks=$((checks + 1))
[ "$(path_state "$work/i3-mac-home" "$fake_applications")" = "$i3_mac_before" ] ||
	fail "i3-dmg: the refused install changed something"

# legacy_layout installs v0.1.11 for real into <home> (tree, links, menu
# entry, marked skill, PATH line), then registers the pre-rename service the
# way its ah would, on <db>, and puts the node's files and another app's
# files in the pre-rename data directory.
legacy_layout() { # legacy_layout <home> <db or "">
	local home=$1 db=$2
	mkdir -p "$home"
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$home/.claude" \
		sandboxed "$home" sh "$installer" --from "$legacy_tgz" --no-service >"$home.legacy-install.txt" 2>&1 ||
		{
			fail "legacy layout: the v0.1.11 install failed: $(cat "$home.legacy-install.txt")"
			return 1
		}
	make_unit "$home" linux "$home/.local/share/agenthub/agenthub-node" "$db"
	mkdir -p "$home/.config/agenthub/approvals" "$home/.config/agenthub/claims" "$home/.config/agenthub/hooks"
	echo key >"$home/.config/agenthub/node.key"
	echo db >"$home/.config/agenthub/agenthub.db"
	echo wal >"$home/.config/agenthub/agenthub.db-wal"
	echo theirs >"$home/.config/agenthub/session_metadata.sqlite"
	echo theirs >"$home/.config/agenthub/approvals/a.json"
	echo theirs >"$home/.config/agenthub/claims/b"
	printf '#!/bin/sh\n' >"$home/.config/agenthub/hooks/c.sh"
}

# current_run installs v0.2.0 for real into <home> from the local release.
current_run() { # current_run <home> <output file> [args...]
	local home=$1 out=$2
	shift 2
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$home/.claude" \
		FAKE_AH_LOG="$home.ah.log" sandboxed "$home" sh "$installer" --from "$current_tgz" "$@" >"$out" 2>&1
}

echo "== I4 upgrading a v0.1.11 Linux install =="
i4_home="$work/i4-home"
legacy_layout "$i4_home" "$i4_home/.config/agenthub/agenthub.db"
cp "$i4_home/.bashrc" "$work/i4-bashrc.before"
contains i4-setup "$i4_home/.bashrc" "# added by the AgentHub installer"
i4_data_before=$(path_state "$i4_home/.config/agenthub")
checks=$((checks + 1))
current_run "$i4_home" "$work/i4-dry.txt" --dry-run || fail "i4-dry: failed: $(cat "$work/i4-dry.txt")"
if assert_confined i4-dry "$work/i4-dry.txt"; then
	checks=$((checks + 1))
	current_run "$i4_home" "$work/i4.txt" || fail "i4: the upgrade failed: $(cat "$work/i4.txt")"
	contains i4 "$i4_home.ah.log" "service install --db $i4_home/.config/agenthub/agenthub.db"
	contains i4 "$work/i4.txt" "keeping the node's database at $i4_home/.config/agenthub/agenthub.db"
	for present in .local/share/agenthallway/agenthallway-node .local/bin/agenthallway-desktop \
		.local/share/applications/agenthallway.desktop .claude/skills/agenthallway-watch/.agenthallway-install \
		.config/systemd/user/agenthallway-node.service; do
		checks=$((checks + 1))
		exists_path "$i4_home/$present" || fail "i4: $present is missing after the upgrade"
	done
	checks=$((checks + 1))
	[ "$(readlink "$i4_home/.local/bin/ah")" = "$i4_home/.local/share/agenthallway/ah" ] ||
		fail "i4: ~/.local/bin/ah points at $(readlink "$i4_home/.local/bin/ah")"
	for gone in .local/share/agenthub .local/bin/agenthub-desktop .local/share/applications/agenthub.desktop \
		.claude/skills/agenthub-watch .config/systemd/user/agenthub-node.service; do
		checks=$((checks + 1))
		! exists_path "$i4_home/$gone" || fail "i4: the pre-rename $gone is still there"
	done
	checks=$((checks + 1))
	[ "$(path_state "$i4_home/.config/agenthub")" = "$i4_data_before" ] ||
		fail "i4: install.sh changed the data directory; only the node moves its files"
	checks=$((checks + 1))
	cmp -s "$i4_home/.bashrc" "$work/i4-bashrc.before" || fail "i4: .bashrc changed: $(cat "$i4_home/.bashrc")"
	contains i4 "$work/i4.txt" "$i4_home/.bashrc already adds"
	contains i4 "$work/i4.txt" "removed the pre-rename AgentHub install:"
	contains i4 "$work/i4.txt" "pre-rename install: removed:"
	lacks i4 "$work/i4.txt" "warning: the pre-rename background service"
	# The dry run printed the retirement it would do, and did nothing.
	contains i4-dry "$work/i4-dry.txt" "the commands above remove the pre-rename AgentHub install:"
fi

echo "== I5 --no-service keeps a pre-rename install whose service is registered =="
i5_home="$work/i5-home"
legacy_layout "$i5_home" ""
checks=$((checks + 1))
current_run "$i5_home" "$work/i5.txt" --no-service || fail "i5: the install failed: $(cat "$work/i5.txt")"
contains i5 "$work/i5.txt" "warning: the pre-rename background service $i5_home/.config/systemd/user/agenthub-node.service is still registered"
contains i5 "$work/i5.txt" "pre-rename install: kept, because its background service is still registered"
for kept in .local/share/agenthub/agenthub-node .local/bin/agenthub-desktop .config/systemd/user/agenthub-node.service \
	.claude/skills/agenthub-watch .local/share/applications/agenthub.desktop .local/share/agenthallway/agenthallway-node; do
	checks=$((checks + 1))
	exists_path "$i5_home/$kept" || fail "i5: $kept is gone"
done
: >>"$i5_home.ah.log"
lacks i5 "$i5_home.ah.log" "service install"

echo "== I6 upgrading a v0.1.11 macOS install =="
i6_home="$work/i6-home"
i6_apps="$work/i6-Applications"
i6_dmg="$work/i6-dmg"
i6_contents="$work/i6-dmg-contents"
mac_bundle "$i6_apps/agenthub-desktop.app" "$work/i6-old-ah.log"
mac_bundle "$i6_home/Applications/agenthub-desktop.app" "$work/i6-old-home-ah.log"
printf '#!/bin/sh\n' >"$i6_apps/agenthub-desktop.app/Contents/MacOS/desktop"
mkdir -p "$i6_home/.local/bin" "$i6_home/Library/Caches/com.wails.agenthub-desktop" \
	"$i6_home/Library/WebKit/com.wails.agenthub-desktop" "$i6_home/Library/Preferences"
touch "$i6_home/Library/Preferences/com.wails.agenthub-desktop.plist"
ln -s "$i6_apps/agenthub-desktop.app/Contents/MacOS/ah" "$i6_home/.local/bin/ah"
make_unit "$i6_home" darwin "$i6_apps/agenthub-desktop.app/Contents/MacOS/agenthub-node"
mkdir -p "$i6_contents/agenthallway-desktop.app/Contents/MacOS" "$i6_contents/.skills/agenthallway-watch" "$i6_dmg"
current_ah_script "$i6_contents/agenthallway-desktop.app/Contents/MacOS/ah"
for binary in desktop agenthallway-node agenthallway-mcp; do
	printf '#!/bin/sh\n' >"$i6_contents/agenthallway-desktop.app/Contents/MacOS/$binary"
done
echo "(fake skill)" >"$i6_contents/.skills/agenthallway-watch/SKILL.md"
echo "not really a disk image" >"$i6_dmg/agenthallway-desktop_v0.2.0_darwin_universal.dmg"
sums_beside "$i6_dmg/agenthallway-desktop_v0.2.0_darwin_universal.dmg"
i6_run() { # i6_run <output file> [args...]
	local out=$1
	shift
	PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh CLAUDE_CONFIG_DIR="$i6_home/.claude" \
		SB_APPLICATIONS="$i6_apps" SB_DMG_SOURCE="$i6_contents" FAKE_AH_LOG="$work/i6-ah.log" \
		SB_RUNNING_ONCE="$i6_apps/agenthub-desktop.app/Contents/MacOS/desktop" SB_RUNNING_ONCE_SEEN="$out.seen" \
		sandboxed "$i6_home" sh "$installer" --from "$i6_dmg/agenthallway-desktop_v0.2.0_darwin_universal.dmg" "$@" >"$out" 2>&1
}
checks=$((checks + 1))
i6_run "$work/i6-dry.txt" --dry-run || fail "i6-dry: failed: $(cat "$work/i6-dry.txt")"
if assert_confined i6-dry "$work/i6-dry.txt"; then
	i6_log_start=$(($(wc -l <"$work/system-shims.log") + 1))
	checks=$((checks + 1))
	i6_run "$work/i6.txt" || fail "i6: the upgrade failed: $(cat "$work/i6.txt")"
	tail -n +"$i6_log_start" "$work/system-shims.log" >"$work/i6-shims.log"
	contains i6 "$work/i6.txt" "agenthub-desktop is running; asking it to quit before its bundle is removed"
	contains i6 "$work/i6.txt" "agenthub-desktop quit"
	checks=$((checks + 1))
	[ "$(grep -c 'osascript -e quit app "agenthub-desktop"' "$work/i6-shims.log")" = 1 ] ||
		fail "i6: osascript was not asked exactly once to quit the running pre-rename app: $(grep osascript "$work/i6-shims.log")"
	lacks i6 "$work/i6-shims.log" 'quit app "agenthallway-desktop"'
	contains i6 "$work/i6-shims.log" "open $i6_apps/agenthallway-desktop.app"
	for gone in "$i6_apps/agenthub-desktop.app" "$i6_home/Applications/agenthub-desktop.app" \
		"$i6_home/Library/Caches/com.wails.agenthub-desktop" "$i6_home/Library/WebKit/com.wails.agenthub-desktop" \
		"$i6_home/Library/Preferences/com.wails.agenthub-desktop.plist" \
		"$i6_home/Library/LaunchAgents/local.agenthub.node.plist"; do
		checks=$((checks + 1))
		! exists_path "$gone" || fail "i6: $gone is still there"
	done
	for present in "$i6_apps/agenthallway-desktop.app/Contents/MacOS/ah" \
		"$i6_home/Library/LaunchAgents/local.agenthallway.node.plist" "$i6_home/.claude/skills/agenthallway-watch/SKILL.md"; do
		checks=$((checks + 1))
		exists_path "$present" || fail "i6: $present is missing"
	done
	checks=$((checks + 1))
	[ "$(readlink "$i6_home/.local/bin/ah")" = "$i6_apps/agenthallway-desktop.app/Contents/MacOS/ah" ] ||
		fail "i6: ~/.local/bin/ah points at $(readlink "$i6_home/.local/bin/ah")"
	lacks i6 "$work/i6-shims.log" "ditto shim: refusing"
fi

echo "== I6b a pre-rename app this account cannot remove is named, not claimed =="
# The pre-rename app went to /Applications while this account was an admin;
# it no longer is, so the upgrade installs into ~/Applications and cannot
# delete the old bundle. Not root: root writes anyway.
if [ "$(id -u)" -ne 0 ]; then
	i6b_home="$work/i6b-home"
	i6b_apps="$work/i6b-Applications"
	mac_bundle "$i6b_apps/agenthub-desktop.app" "$work/i6b-old-ah.log"
	mkdir -p "$i6b_home"
	chmod 555 "$i6b_apps"
	i6b_run() { # i6b_run <output file> [args...]
		local out=$1
		shift
		PATH="$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh CLAUDE_CONFIG_DIR="$i6b_home/.claude" \
			SB_APPLICATIONS="$i6b_apps" SB_DMG_SOURCE="$i6_contents" FAKE_AH_LOG="$work/i6b-ah.log" \
			sandboxed "$i6b_home" sh "$installer" --from "$i6_dmg/agenthallway-desktop_v0.2.0_darwin_universal.dmg" \
			--no-service --no-open "$@" >"$out" 2>&1
	}
	checks=$((checks + 1))
	i6b_run "$work/i6b-dry.txt" --dry-run || fail "i6b-dry: failed: $(cat "$work/i6b-dry.txt")"
	if assert_confined i6b-dry "$work/i6b-dry.txt"; then
		checks=$((checks + 1))
		i6b_run "$work/i6b.txt" || fail "i6b: the upgrade failed: $(cat "$work/i6b.txt")"
		contains i6b "$work/i6b.txt" "could not remove $i6b_apps/agenthub-desktop.app"
		contains i6b "$work/i6b.txt" "pre-rename install: partly removed; delete what is left yourself: $i6b_apps/agenthub-desktop.app"
		lacks i6b "$work/i6b.txt" "removed the pre-rename AgentHub install"
		checks=$((checks + 1))
		[ -x "$i6b_home/Applications/agenthallway-desktop.app/Contents/MacOS/ah" ] || fail "i6b: the new app is not in ~/Applications"
	fi
	chmod 755 "$i6b_apps"
fi

echo "== I7 an owner's own agenthub-watch is left by the upgrade =="
for i7_kind in link copy; do
	i7_home="$work/i7-home-$i7_kind"
	tree_at "$i7_home/.local/share/agenthub" "$work/i7-ah.log" "" 0
	mkdir -p "$i7_home/.claude/skills" "$work/i7-own-$i7_kind/agenthub-watch"
	echo mine >"$work/i7-own-$i7_kind/agenthub-watch/SKILL.md"
	if [ "$i7_kind" = link ]; then
		ln -s "$work/i7-own-$i7_kind/agenthub-watch" "$i7_home/.claude/skills/agenthub-watch"
	else
		cp -R "$work/i7-own-$i7_kind/agenthub-watch" "$i7_home/.claude/skills/agenthub-watch"
	fi
	checks=$((checks + 1))
	current_run "$i7_home" "$work/i7-$i7_kind.txt" --no-service || fail "i7-$i7_kind: failed: $(cat "$work/i7-$i7_kind.txt")"
	checks=$((checks + 1))
	! exists_path "$i7_home/.local/share/agenthub" || fail "i7-$i7_kind: the pre-rename tree was not retired"
	checks=$((checks + 1))
	[ "$(cat "$i7_home/.claude/skills/agenthub-watch/SKILL.md" 2>/dev/null)" = mine ] ||
		fail "i7-$i7_kind: the owner's agenthub-watch was removed or changed"
	if [ "$i7_kind" = link ]; then
		checks=$((checks + 1))
		[ -L "$i7_home/.claude/skills/agenthub-watch" ] || fail "i7-link: the owner's link was replaced"
	fi
done

echo "== I8 a pre-rename release refuses to install over migrated data =="
i8_home="$work/i8-home"
mkdir -p "$i8_home/.config/agenthallway"
echo key >"$i8_home/.config/agenthallway/node.key"
i8_before=$(path_state "$i8_home")
i8_run() { # i8_run <output file> [args...]
	local out=$1
	shift
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$i8_home/.claude" \
		sandboxed "$i8_home" sh "$installer" "$@" >"$out" 2>&1
}
checks=$((checks + 1))
if i8_run "$work/i8.txt" --from "$legacy_tgz"; then
	fail "i8: a pre-rename release was installed over a machine whose node has moved"
fi
contains i8 "$work/i8.txt" "is from before the rename to Agent Hallway"
contains i8 "$work/i8.txt" "$i8_home/.config/agenthallway/node.key"
contains i8 "$work/i8.txt" "service install --db \"$i8_home/.config/agenthallway/agenthallway.db\""
contains i8 "$work/i8.txt" "Nothing was installed."
checks=$((checks + 1))
[ "$(path_state "$i8_home")" = "$i8_before" ] || fail "i8: the refused install changed $i8_home"
# The tag on the command line is the one the recipe reinstalls.
i8_dry_home="$work/i8-dry-home"
mkdir -p "$i8_dry_home/.config/agenthallway"
echo key >"$i8_dry_home/.config/agenthallway/node.key"
checks=$((checks + 1))
if PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
	sandboxed "$i8_dry_home" sh "$installer" --dry-run --version v0.1.11 --cli-only >"$work/i8-dry.txt" 2>&1; then
	fail "i8-dry: a dry run of a pre-rename tag over moved data did not refuse"
fi
contains i8-dry "$work/i8-dry.txt" "sh -s -- --version v0.1.11 --no-service"
# A current install on the machine is the same refusal.
i8_unit_home="$work/i8-unit-home"
make_current_unit "$i8_unit_home" linux "$i8_unit_home/.local/share/agenthallway/agenthallway-node"
checks=$((checks + 1))
if PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
	sandboxed "$i8_unit_home" sh "$installer" --from "$legacy_tgz" >"$work/i8-unit.txt" 2>&1; then
	fail "i8-unit: a pre-rename release was installed over a registered Agent Hallway service"
fi
contains i8-unit "$work/i8-unit.txt" "$i8_unit_home/.config/systemd/user/agenthallway-node.service"
# --no-service installs the pre-rename layout, registers nothing, and prints
# the recipe.
checks=$((checks + 1))
i8_run "$work/i8-noservice.txt" --from "$legacy_tgz" --no-service || fail "i8-noservice: failed: $(cat "$work/i8-noservice.txt")"
contains i8-noservice "$work/i8-noservice.txt" "is installed because of --no-service"
contains i8-noservice "$work/i8-noservice.txt" "service install --db \"$i8_home/.config/agenthallway/agenthallway.db\""
checks=$((checks + 1))
[ -x "$i8_home/.local/share/agenthub/agenthub-node" ] || fail "i8-noservice: the pre-rename layout was not installed"
checks=$((checks + 1))
[ -f "$i8_home/.config/agenthallway/node.key" ] || fail "i8-noservice: the moved identity is gone"

echo "== I9 --uninstall removes both the new and the pre-rename installs =="
i9_home="$work/i9-home"
mkdir -p "$i9_home"
printf 'alias keep=1\n' >"$i9_home/.bashrc"
printf 'alias keep=1\n' >"$work/i9-owner-lines"
checks=$((checks + 1))
current_run "$i9_home" "$work/i9-install.txt" --no-service || fail "i9: the current install failed: $(cat "$work/i9-install.txt")"
contains i9 "$i9_home/.bashrc" "# added by the Agent Hallway installer"
# The pre-rename install beside it, as v0.1.11 left it.
tree_at "$i9_home/.local/share/agenthub" "$work/i9-old-ah.log" "" 0
printf '#!/bin/sh\n' >"$i9_home/.local/share/agenthub/agenthub-desktop"
ln -s "$i9_home/.local/share/agenthub/agenthub-desktop" "$i9_home/.local/bin/agenthub-desktop"
printf '[Desktop Entry]\nExec="%s"\n' "$i9_home/.local/share/agenthub/agenthub-desktop" \
	>"$i9_home/.local/share/applications/agenthub.desktop"
mkdir -p "$i9_home/.claude/skills/agenthub-watch" "$i9_home/.config/fish/conf.d"
touch "$i9_home/.claude/skills/agenthub-watch/.agenthub-install"
# shellcheck disable=SC2016 # literal startup-file lines
printf 'export KEEP=1\n\n# added by the AgentHub installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >"$i9_home/.profile"
printf 'export KEEP=1\n' >"$work/i9-profile-after"
# shellcheck disable=SC2016 # literal fish lines
printf '\n# added by the AgentHub installer\ncontains -- $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH\n' \
	>"$i9_home/.config/fish/conf.d/agenthub.fish"
# shellcheck disable=SC2016 # literal fish lines
printf '\n# added by the Agent Hallway installer\ncontains -- $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH\n' \
	>"$i9_home/.config/fish/conf.d/agenthallway.fish"
make_unit "$i9_home" linux "$i9_home/.local/share/agenthub/agenthub-node"
make_current_unit "$i9_home" linux "$i9_home/.local/share/agenthallway/agenthallway-node"
i9_run() { # i9_run <output file> [args...]
	local out=$1
	shift
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$i9_home/.claude" \
		FAKE_AH_LOG="$work/i9-ah.log" sandboxed "$i9_home" sh "$installer" --uninstall "$@" >"$out" 2>&1
}
checks=$((checks + 1))
i9_run "$work/i9-dry.txt" --dry-run || fail "i9-dry: failed: $(cat "$work/i9-dry.txt")"
if assert_confined i9-dry "$work/i9-dry.txt"; then
	: >"$work/i9-ah.log"
	checks=$((checks + 1))
	i9_run "$work/i9.txt" || fail "i9: --uninstall failed: $(cat "$work/i9.txt")"
	checks=$((checks + 1))
	[ "$(grep -c 'service uninstall' "$work/i9-ah.log")" = 1 ] ||
		fail "i9: the current ah was not asked exactly once to take both services down: $(cat "$work/i9-ah.log")"
	for gone in .local/share/agenthallway .local/share/agenthub .local/bin/ah .local/bin/agenthallway-desktop \
		.local/bin/agenthub-desktop .local/share/applications/agenthallway.desktop \
		.local/share/applications/agenthub.desktop .claude/skills/agenthallway-watch .claude/skills/agenthub-watch \
		.config/fish/conf.d/agenthub.fish .config/fish/conf.d/agenthallway.fish \
		.config/systemd/user/agenthub-node.service .config/systemd/user/agenthallway-node.service; do
		checks=$((checks + 1))
		! exists_path "$i9_home/$gone" || fail "i9: $gone is still there"
	done
	checks=$((checks + 1))
	cmp -s "$i9_home/.bashrc" "$work/i9-owner-lines" || fail "i9: .bashrc is not the owner's lines alone: $(cat "$i9_home/.bashrc")"
	checks=$((checks + 1))
	cmp -s "$i9_home/.profile" "$work/i9-profile-after" || fail "i9: .profile kept a pre-rename PATH line: $(cat "$i9_home/.profile")"
	contains i9 "$work/i9.txt" "done. Agent Hallway is uninstalled."
fi

echo "== I10/I11 --purge deletes only our files from a data directory another app shares =="
for i10_os in darwin linux; do
	i10_home="$work/i10-home-$i10_os"
	if [ "$i10_os" = darwin ]; then
		i10_old="$i10_home/Library/Application Support/agenthub"
		i10_new="$i10_home/Library/Application Support/agenthallway"
		i10_log_old="$i10_home/Library/Logs/agenthub"
		i10_log_new="$i10_home/Library/Logs/agenthallway"
		i10_uname=$(fake_uname Darwin arm64)
	else
		i10_old="$i10_home/.config/agenthub"
		i10_new="$i10_home/.config/agenthallway"
		i10_log_old="$i10_home/.local/state/agenthub"
		i10_log_new="$i10_home/.local/state/agenthallway"
		i10_uname=$(fake_uname Linux x86_64)
	fi
	mkdir -p "$i10_old/approvals" "$i10_old/claims" "$i10_old/hooks" "$i10_new" "$i10_log_old" "$i10_log_new"
	for ours in node.key agenthub.db agenthub.db-wal agenthub.db-shm .node.key-123; do
		echo ours >"$i10_old/$ours"
	done
	for ours in node.key agenthallway.db .migrating-from-agenthub; do
		echo ours >"$i10_new/$ours"
	done
	echo theirs >"$i10_old/session_metadata.sqlite"
	echo theirs >"$i10_old/approvals/a.json"
	echo theirs >"$i10_old/claims/b"
	printf '#!/bin/sh\n' >"$i10_old/hooks/c.sh"
	echo log >"$i10_log_old/node.log"
	echo theirs >"$i10_log_old/their.log"
	echo log >"$i10_log_new/node.log"
	i10_foreign_before=$(path_state "$i10_old/session_metadata.sqlite" "$i10_old/approvals" "$i10_old/claims" \
		"$i10_old/hooks" "$i10_log_old/their.log")
	# An Applications of its own: the shared fake one holds a pre-rename app,
	# which a macOS uninstall would rightly remove.
	mkdir -p "$work/i10-Applications"
	i10_run() { # i10_run <output file> [args...]
		local out=$1
		shift
		PATH="$i10_uname:$bare_path" SHELL=/bin/bash SB_APPLICATIONS="$work/i10-Applications" \
			sandboxed "$i10_home" sh "$installer" --uninstall --purge "$@" >"$out" 2>&1
	}
	checks=$((checks + 1))
	i10_run "$work/i10-$i10_os-dry.txt" --dry-run || fail "i10-$i10_os-dry: failed: $(cat "$work/i10-$i10_os-dry.txt")"
	commands_only "$work/i10-$i10_os-dry.txt" "$work/i10-$i10_os-dry.cmds"
	# I11: files with rm -f, directories with rmdir, and never rm -rf on a data
	# or log directory, or anything inside one.
	for i11_dir in "$i10_old" "$i10_new" "$i10_log_old" "$i10_log_new"; do
		checks=$((checks + 1))
		if grep -F -- "+ rm -rf" "$work/i10-$i10_os-dry.cmds" | grep -qF -- "$i11_dir"; then
			fail "i11-$i10_os: an rm -rf names $i11_dir: $(grep -F -- '+ rm -rf' "$work/i10-$i10_os-dry.cmds")"
		fi
	done
	contains "i11-$i10_os" "$work/i10-$i10_os-dry.cmds" "rm -f $(quote_for_test "$i10_old/node.key")"
	contains "i11-$i10_os" "$work/i10-$i10_os-dry.cmds" "rm -f $(quote_for_test "$i10_old/.node.key-123")"
	contains "i11-$i10_os" "$work/i10-$i10_os-dry.cmds" "rmdir $(quote_for_test "$i10_new")"
	contains "i11-$i10_os" "$work/i10-$i10_os-dry.cmds" "rmdir $(quote_for_test "$i10_log_new")"
	lacks "i11-$i10_os" "$work/i10-$i10_os-dry.cmds" "rmdir $(quote_for_test "$i10_old")"
	contains "i11-$i10_os" "$work/i10-$i10_os-dry.txt" "left $i10_old: it holds files that are not Agent Hallway's (approvals, claims, hooks, session_metadata.sqlite)"
	if assert_confined "i10-$i10_os-dry" "$work/i10-$i10_os-dry.txt"; then
		checks=$((checks + 1))
		i10_run "$work/i10-$i10_os.txt" || fail "i10-$i10_os: failed: $(cat "$work/i10-$i10_os.txt")"
		for gone in node.key agenthub.db agenthub.db-wal agenthub.db-shm .node.key-123; do
			checks=$((checks + 1))
			! exists_path "$i10_old/$gone" || fail "i10-$i10_os: $gone is still in the shared directory"
		done
		for gone in "$i10_new" "$i10_log_new" "$i10_log_old/node.log"; do
			checks=$((checks + 1))
			! exists_path "$gone" || fail "i10-$i10_os: $gone is still there"
		done
		checks=$((checks + 1))
		[ "$(path_state "$i10_old/session_metadata.sqlite" "$i10_old/approvals" "$i10_old/claims" \
			"$i10_old/hooks" "$i10_log_old/their.log")" = "$i10_foreign_before" ] ||
			fail "i10-$i10_os: another app's files changed"
		checks=$((checks + 1))
		if ! { [ -d "$i10_old" ] && [ -d "$i10_log_old" ]; }; then
			fail "i10-$i10_os: a directory another app shares was removed"
		fi
		contains "i10-$i10_os" "$work/i10-$i10_os.txt" "installing again makes a new node"
	fi
done

echo "== I12 either PATH comment counts =="
# Installing: the pre-rename comment already adds the line, so nothing is
# appended (I4 asserts the same for .bashrc through a whole upgrade); for fish
# the pre-rename file is the one that counts.
i12_home="$work/i12-home"
mkdir -p "$i12_home/.config/fish/conf.d"
# shellcheck disable=SC2016 # literal fish lines
printf '\n# added by the AgentHub installer\ncontains -- $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH\n' \
	>"$i12_home/.config/fish/conf.d/agenthub.fish"
checks=$((checks + 1))
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/usr/bin/fish CLAUDE_CONFIG_DIR="$i12_home/.claude" \
	sandboxed "$i12_home" sh "$installer" --from "$current_tgz" --no-service >"$work/i12.txt" 2>&1 ||
	fail "i12: failed: $(cat "$work/i12.txt")"
contains i12 "$work/i12.txt" "$i12_home/.config/fish/conf.d/agenthub.fish already adds"
checks=$((checks + 1))
! exists_path "$i12_home/.config/fish/conf.d/agenthallway.fish" || fail "i12: a second fish PATH file was written"
# Uninstalling: both comments' blocks go from one file, the owner's lines stay.
i12_un_home="$work/i12-un-home"
mkdir -p "$i12_un_home"
# shellcheck disable=SC2016 # literal startup-file lines
printf 'alias keep=1\n\n# added by the AgentHub installer\nexport PATH="$HOME/.local/bin:$PATH"\nalias also=1\n\n# added by the Agent Hallway installer\nexport PATH="$HOME/.local/bin:$PATH"\n' \
	>"$i12_un_home/.bashrc"
printf 'alias keep=1\nalias also=1\n' >"$work/i12-bashrc-after"
checks=$((checks + 1))
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
	sandboxed "$i12_un_home" sh "$installer" --uninstall >"$work/i12-un.txt" 2>&1 || fail "i12-un: failed: $(cat "$work/i12-un.txt")"
checks=$((checks + 1))
cmp -s "$i12_un_home/.bashrc" "$work/i12-bashrc-after" || fail "i12-un: .bashrc is $(cat "$i12_un_home/.bashrc")"

echo "== I13 a stale MCP entry is reported and never written =="
i13_home="$work/i13-home"
mkdir -p "$i13_home/claude-config" "$i13_home/codex"
printf '{"mcpServers":{"agenthub":{"command":"/x/agenthub-mcp"}}}\n' >"$i13_home/.claude.json"
printf '{"mcpServers":{"agenthub":{"command":"/y/agenthub-mcp"}}}\n' >"$i13_home/claude-config/.claude.json"
printf '[mcp_servers.agenthub]\ncommand = "/z/agenthub-mcp"\n' >"$i13_home/codex/config.toml"
i13_before=$(path_state "$i13_home/.claude.json" "$i13_home/claude-config/.claude.json" "$i13_home/codex/config.toml")
for i13_mode in --dry-run ""; do
	checks=$((checks + 1))
	# shellcheck disable=SC2086 # the empty mode is meant to vanish
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$i13_home/claude-config" \
		CODEX_HOME="$i13_home/codex" sandboxed "$i13_home" sh "$installer" --from "$current_tgz" --no-service $i13_mode \
		>"$work/i13.txt" 2>&1 || fail "i13$i13_mode: failed: $(cat "$work/i13.txt")"
	contains "i13$i13_mode" "$work/i13.txt" "these still start agenthub-mcp, which this upgrade removed:"
	contains "i13$i13_mode" "$work/i13.txt" "$i13_home/claude-config/.claude.json"
	contains "i13$i13_mode" "$work/i13.txt" "$i13_home/.claude.json"
	contains "i13$i13_mode" "$work/i13.txt" "$i13_home/codex/config.toml"
	contains "i13$i13_mode" "$work/i13.txt" "mcp__agenthallway__*"
	# Advice that can be followed: the entry to write, naming the binary this
	# run installed. The app has had no MCP button since the row action went.
	contains "i13$i13_mode" "$work/i13.txt" \
		"Replace that entry with one keyed agenthallway whose command is $i13_home/.local/share/agenthallway/agenthallway-mcp and whose arguments are the old entry's"
	lacks "i13$i13_mode" "$work/i13.txt" "MCP config button"
	checks=$((checks + 1))
	[ "$(path_state "$i13_home/.claude.json" "$i13_home/claude-config/.claude.json" "$i13_home/codex/config.toml")" = "$i13_before" ] ||
		fail "i13$i13_mode: an MCP configuration was written"
done
# A pre-rename install says nothing about MCP: its entries are still right.
mkdir -p "$work/i13-legacy-home"
checks=$((checks + 1))
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$i13_home/claude-config" \
	CODEX_HOME="$i13_home/codex" sandboxed "$work/i13-legacy-home" sh "$installer" --from "$legacy_tgz" --no-service --dry-run \
	>"$work/i13-legacy.txt" 2>&1 || fail "i13-legacy: failed: $(cat "$work/i13-legacy.txt")"
lacks i13-legacy "$work/i13-legacy.txt" "these still start"
# The release notes and this script's documentation give the same advice.
for i13_doc in "$repository/.github/workflows/release.yml" "$repository/docs/install-script.md"; do
	lacks i13-docs "$i13_doc" "MCP config button"
done
contains i13-docs "$repository/.github/workflows/release.yml" "the arguments are the old entry's"
contains i13-docs "$repository/docs/install-script.md" "one keyed \`agenthallway\` whose command is the \`agenthallway-mcp\`"

echo "== I14 the pre-rename environment names still work =="
mkdir -p "$work/i14-home"
i14_dry() { # i14_dry <output file> <env assignments and installer args...>
	local out=$1
	shift
	PATH="$no_service_ah:$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
		sandboxed "$work/i14-home" env "$@" >"$out" 2>&1
}
i14_dry "$work/i14-version.txt" AGENTHUB_VERSION=v0.2.0 sh "$installer" --dry-run --cli-only
contains i14-version "$work/i14-version.txt" "agenthallway_v0.2.0_linux_amd64.tar.gz"
i14_dry "$work/i14-version-both.txt" AGENTHUB_VERSION=v0.1.11 AGENTHALLWAY_VERSION=v0.2.0 sh "$installer" --dry-run --cli-only
contains i14-version-both "$work/i14-version-both.txt" "agenthallway_v0.2.0_linux_amd64.tar.gz"
i14_dry "$work/i14-version-old.txt" AGENTHUB_VERSION=v0.1.11 sh "$installer" --dry-run --cli-only
contains i14-version-old "$work/i14-version-old.txt" "agenthub_v0.1.11_linux_amd64.tar.gz"
i14_dry "$work/i14-home-both.txt" AGENTHUB_HOME="$work/i14-old-tree" AGENTHALLWAY_HOME="$work/i14-new-tree" \
	sh "$installer" --dry-run --version v0.2.0 --cli-only
contains i14-home-both "$work/i14-home-both.txt" "installed $work/i14-new-tree"
# The pre-rename Applications knob alone: the new one unset, and the fallback
# must stop at it rather than reach the real /Applications.
mkdir -p "$work/i14-Applications"
PATH="$no_service_ah:$(fake_uname Darwin arm64):$bare_path" SHELL=/bin/zsh \
	sandboxed "$work/i14-home" env -u AGENTHALLWAY_APPLICATIONS AGENTHUB_APPLICATIONS="$work/i14-Applications" \
	sh "$installer" --dry-run --version v0.2.0 --no-open >"$work/i14-apps.txt" 2>&1
contains i14-apps "$work/i14-apps.txt" "installed $work/i14-Applications/agenthallway-desktop.app"
lacks i14-apps "$work/i14-apps.txt" " /Applications/"
# An AGENTHUB_HOME tree is upgraded in place: the same directory, now holding
# the current binaries, and not retired afterwards.
i14_tree="$work/i14-ahome"
i14_real_home="$work/i14-real-home"
mkdir -p "$i14_real_home"
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$i14_real_home/.claude" \
	sandboxed "$i14_real_home" env AGENTHUB_HOME="$i14_tree" sh "$installer" --from "$legacy_tgz" --no-service \
	>"$work/i14-legacy.txt" 2>&1 || fail "i14-inplace: the v0.1.11 install failed: $(cat "$work/i14-legacy.txt")"
checks=$((checks + 1))
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$i14_real_home/.claude" \
	sandboxed "$i14_real_home" env AGENTHUB_HOME="$i14_tree" sh "$installer" --from "$current_tgz" --no-service \
	>"$work/i14-inplace.txt" 2>&1 || fail "i14-inplace: the upgrade failed: $(cat "$work/i14-inplace.txt")"
checks=$((checks + 1))
if ! { [ -x "$i14_tree/agenthallway-node" ] && [ -x "$i14_tree/ah" ]; }; then
	fail "i14-inplace: $i14_tree does not hold the current release"
fi
checks=$((checks + 1))
! exists_path "$i14_tree/agenthub-node" || fail "i14-inplace: the tree still holds the pre-rename binaries"
checks=$((checks + 1))
! exists_path "$i14_real_home/.local/bin/agenthub-desktop" || fail "i14-inplace: the stale pre-rename link was left"
checks=$((checks + 1))
! exists_path "$i14_real_home/.local/share/applications/agenthub.desktop" || fail "i14-inplace: the stale pre-rename menu entry was left"
contains i14-inplace "$work/i14-inplace.txt" "installed $i14_tree"
lacks i14-inplace "$work/i14-inplace.txt" "removed $i14_tree"

echo "== the current era: a real install, its menu entry, a refusal, an upgrade =="
cur_home="$work/cur-home"
cur_xdg="$work/cur-xdg"
mkdir -p "$cur_home"
cur_install() { # cur_install <output file> <archive> [args...]
	local out=$1 archive=$2
	shift 2
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$cur_home/.claude" \
		sandboxed "$cur_home" env XDG_DATA_HOME="$cur_xdg" sh "$installer" --from "$archive" \
		--prefix "$work/cur-pfx" --no-service "$@" >"$out" 2>&1
}
checks=$((checks + 1))
cur_install "$work/cur.txt" "$current_tgz" || fail "cur: the install failed: $(cat "$work/cur.txt")"
contains cur "$work/cur.txt" "verified agenthallway-desktop_v0.2.0_linux_amd64.tar.gz against SHA256SUMS"
for binary in ah agenthallway-node agenthallway-mcp agenthallway-desktop; do
	checks=$((checks + 1))
	[ -x "$work/cur-pfx/share/agenthallway/$binary" ] || fail "cur: $binary is missing from the install"
done
checks=$((checks + 1))
[ -f "$work/cur-pfx/.agenthallway-install" ] || fail "cur: the prefix carries no .agenthallway-install marker"
cur_entry="$cur_xdg/applications/agenthallway.desktop"
contains cur-menu "$cur_entry" "Name=Agent Hallway"
contains cur-menu "$cur_entry" "Exec=\"$work/cur-pfx/share/agenthallway/agenthallway-desktop\""
contains cur-menu "$cur_entry" "StartupWMClass=agenthallway-desktop"
contains cur "$work/cur.txt" "done. Agent Hallway is installed:"
checks=$((checks + 1))
cur_install "$work/cur2.txt" "$current_tgz" || fail "cur-rerun: the second install failed: $(cat "$work/cur2.txt")"
contains cur-rerun "$work/cur2.txt" "installed $work/cur-pfx/share/agenthallway"
cur_bad="$work/cur-bad"
mkdir -p "$cur_bad"
cp "$current_tgz" "$cur_bad/"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
	"agenthallway-desktop_v0.2.0_linux_amd64.tar.gz" >"$cur_bad/SHA256SUMS"
checks=$((checks + 1))
if PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
	sandboxed "$cur_home" sh "$installer" --from "$cur_bad/agenthallway-desktop_v0.2.0_linux_amd64.tar.gz" \
	--prefix "$work/cur-refused" --no-service >"$work/cur-bad.txt" 2>&1; then
	fail "cur-bad: a corrupted SHA256SUMS was accepted"
fi
contains cur-bad "$work/cur-bad.txt" "checksum mismatch"
checks=$((checks + 1))
[ ! -e "$work/cur-refused" ] || fail "cur-bad: the refused install still created $work/cur-refused"
# A --prefix upgrade from the pre-rename layout in that prefix: retired inside
# the prefix, and nothing outside it touched.
cur_pfx_old="$work/cur-pfx-old"
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
	sandboxed "$cur_home" env XDG_DATA_HOME="$cur_xdg" sh "$installer" --from "$legacy_tgz" \
	--prefix "$cur_pfx_old" --no-service >"$work/cur-pfx-legacy.txt" 2>&1 ||
	fail "cur-pfx: the v0.1.11 prefix install failed: $(cat "$work/cur-pfx-legacy.txt")"
cur_outside_before=$(path_state "$cur_home")
checks=$((checks + 1))
PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash \
	sandboxed "$cur_home" env XDG_DATA_HOME="$cur_xdg" sh "$installer" --from "$current_tgz" \
	--prefix "$cur_pfx_old" --no-service >"$work/cur-pfx-up.txt" 2>&1 ||
	fail "cur-pfx: the prefix upgrade failed: $(cat "$work/cur-pfx-up.txt")"
for gone in share/agenthub bin/agenthub-desktop .agenthub-install; do
	checks=$((checks + 1))
	! exists_path "$cur_pfx_old/$gone" || fail "cur-pfx: the pre-rename $gone is still in the prefix"
done
checks=$((checks + 1))
! exists_path "$cur_xdg/applications/agenthub.desktop" || fail "cur-pfx: the prefix's pre-rename menu entry was left"
checks=$((checks + 1))
[ "$(path_state "$cur_home")" = "$cur_outside_before" ] || fail "cur-pfx: the prefix upgrade changed $cur_home"

echo "== the current era: the skill =="
cur_skill_cfg="$work/cur-skill"
cur_skill_home="$work/cur-skill-home"
mkdir -p "$cur_skill_home"
cur_skill_run() { # cur_skill_run <output file> [args...]
	local out=$1
	shift
	PATH="$(fake_uname Linux x86_64):$bare_path" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$cur_skill_cfg" \
		sandboxed "$cur_skill_home" sh "$installer" "$@" >"$out" 2>&1
}
checks=$((checks + 1))
cur_skill_run "$work/cur-skill.txt" --from "$current_tgz" --no-service --no-modify-path ||
	fail "cur-skill: failed: $(cat "$work/cur-skill.txt")"
contains cur-skill "$work/cur-skill.txt" "installed the Claude Code skill $cur_skill_cfg/skills/agenthallway-watch"
checks=$((checks + 1))
[ -f "$cur_skill_cfg/skills/agenthallway-watch/.agenthallway-install" ] || fail "cur-skill: the installed skill carries no marker"
echo stale >"$cur_skill_cfg/skills/agenthallway-watch/stale.txt"
checks=$((checks + 1))
cur_skill_run "$work/cur-skill2.txt" --from "$current_tgz" --no-service --no-modify-path ||
	fail "cur-skill-upgrade: failed: $(cat "$work/cur-skill2.txt")"
checks=$((checks + 1))
[ ! -e "$cur_skill_cfg/skills/agenthallway-watch/stale.txt" ] || fail "cur-skill-upgrade: a file of the old copy survived"
checks=$((checks + 1))
cur_skill_run "$work/cur-skill-un.txt" --uninstall || fail "cur-skill-un: failed: $(cat "$work/cur-skill-un.txt")"
checks=$((checks + 1))
! exists_path "$cur_skill_cfg/skills/agenthallway-watch" || fail "cur-skill-un: the installed skill is still there"
checks=$((checks + 1))
! exists_path "$cur_skill_home/.local/share/agenthallway" || fail "cur-skill-un: the tree is still there"

# ---- what the last lines tell a stranger -----------------------------------

echo "== the closing lines say what to do next =="
contains closing "$work/svc-none.txt" "Open $work/pfx/agenthub-desktop.app; it starts on a setup checklist."
contains closing "$work/svc-none.txt" "| sh -s -- --no-service"
contains closing "$work/svc-none.txt" "$work/pfx/bin/ah"
contains closing "$work/svc-none.txt" "node: running as a background service"
contains closing "$work/darwin-cli.txt" "node: not registered (--no-service)"
contains closing "$work/linux.txt" "it starts on a setup checklist."

echo "== the tripwire: this machine's own install is as it was =="
checks=$((checks + 1))
tripwire_check || failures=$((failures + 1))

echo
if [ "$failures" -ne 0 ]; then
	echo "$failures of $checks checks failed" >&2
	exit 1
fi
echo "all $checks checks passed"
