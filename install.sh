#!/bin/sh
# Agent Hallway one-line installer for macOS and Linux.
#
#     curl -fsSL https://raw.githubusercontent.com/SheldonChangL/agenthub/main/install.sh | sh
#
# It picks the one release asset for this machine, verifies it against the
# release's own SHA256SUMS before anything is unpacked, puts it somewhere the
# owner can already write, and registers the background node with launchd or
# `systemd --user`. It never asks for sudo, and the complete list of paths it
# writes and deletes is in docs/install-script.md.
#
# Agent Hallway was called AgentHub up to v0.1.11. A tag from then (v0.0.*,
# v0.1.*) is installed under the names it was released with; any later tag
# under the new ones, after which the pre-rename install is retired. Every
# pre-rename name is a LEGACY_* constant below, so all of that can be found,
# and one day deleted, in one place.
#
# Every statement with an effect lives inside main(), and the last line of the
# file calls it. That is not style: this script is piped into `sh` from the
# network, and a stream cut in half is a file that ends mid-function. With the
# body at the top level, half a file is half an install that exits 0. With the
# call last, half a file defines some functions and runs none of them.
#
# POSIX sh only: this runs under macOS /bin/sh (a bash in POSIX mode) and under
# dash on Debian and Ubuntu, so no arrays, no [[, no local, no +=.
set -eu

REPO="SheldonChangL/agenthub"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"
RAW_SELF="https://raw.githubusercontent.com/${REPO}/main/install.sh"

# The names this product installs under now.
CURRENT_SLUG="agenthallway"
CURRENT_PRODUCT="Agent Hallway"
CURRENT_APP_NAME="agenthallway-desktop"
CURRENT_NODE_NAME="agenthallway-node"
CURRENT_MCP_NAME="agenthallway-mcp"
CURRENT_SKILL_NAME="agenthallway-watch"
CURRENT_MARKER=".agenthallway-install"
CURRENT_PATH_MARK="# added by the Agent Hallway installer"
CURRENT_MENU_FILE="agenthallway.desktop"
CURRENT_FISH_FILE="agenthallway.fish"
CURRENT_BUNDLE_ID="com.wails.agenthallway-desktop"
CURRENT_LABEL="local.agenthallway.node"
CURRENT_UNIT_NAME="agenthallway-node"

# The names releases up to v0.1.11 installed under. They are what a pre-rename
# tag is installed as, and what an upgrade or an uninstall looks for on disk:
# the marker files and the PATH comment below are already in owners' home
# directories, so they have to keep being recognised.
LEGACY_SLUG="agenthub"
LEGACY_PRODUCT="AgentHub"
LEGACY_APP_NAME="agenthub-desktop"
LEGACY_NODE_NAME="agenthub-node"
LEGACY_MCP_NAME="agenthub-mcp"
LEGACY_SKILL_NAME="agenthub-watch"
LEGACY_MARKER=".agenthub-install"
LEGACY_PATH_MARK="# added by the AgentHub installer"
LEGACY_MENU_FILE="agenthub.desktop"
LEGACY_FISH_FILE="agenthub.fish"
LEGACY_BUNDLE_ID="com.wails.agenthub-desktop"
LEGACY_LABEL="local.agenthub.node"
LEGACY_UNIT_NAME="agenthub-node"
# The node's own pre-rename default database file name, and the marker it
# leaves in the new data directory while it moves its files there.
LEGACY_DB_NAME="agenthub.db"
LEGACY_MIGRATION_MARK=".migrating-from-agenthub"
CURRENT_DB_NAME="agenthallway.db"

# Empty counts as unset, as it does for ah (internal/product.Getenv).
VERSION="${AGENTHALLWAY_VERSION:-${AGENTHUB_VERSION:-}}"
CLI_ONLY=0
NO_SERVICE=0
NO_OPEN=0
NO_MODIFY_PATH=0
NO_SKILL=0
UNINSTALL=0
PURGE=0
DRY_RUN=0
PREFIX=""
FROM=""
ERA=""

TEMP_DIR=""
MOUNT_POINT=""

# The Claude Code skill that teaches an agent to use `ah` (`ah inbox`,
# `ah send`, ...). It travels inside the release asset, so the SHA256SUMS check
# above covers it like every binary; it is never fetched on its own. The copy
# this script puts in place carries the install's marker file, which is how an
# upgrade or an uninstall tells it from a link or a copy the owner made
# themselves.
#
# Where the .dmg keeps it: beside the app, hidden, so the drag-to-install
# window still shows only the app and Applications, and outside the bundle, so
# the bundle's signature is not touched.
DMG_SKILL_DIR=".skills"
SKILL_SOURCE=""

AH=""
SERVICE_STATE=""
SERVICE_REGISTERED=0
REMOVE_SKIPPED=""
PATH_STATE=""
SKILL_STATE=""
LEGACY_STATE=""

# set_names <current|legacy> sets the names this run installs under.
#
# MARKER: a directory this script put an install in carries this file, so a
# later run can tell "the prefix I installed into" from "a directory of the
# owner's that happens to be named on the command line". Without it, --prefix
# ~/Documents would be a delete. The installed skill carries the same file.
#
# PATH_MARK is the comment above the line this script adds to a shell startup
# file. A second run looks for it rather than for "a line that mentions
# .local/bin", which an owner's own file can have for reasons of its own.
set_names() { # set_names <current|legacy>
	ERA="$1"
	if [ "$1" = legacy ]; then
		SLUG="$LEGACY_SLUG"
		PRODUCT="$LEGACY_PRODUCT"
		APP_NAME="$LEGACY_APP_NAME"
		NODE_NAME="$LEGACY_NODE_NAME"
		MCP_NAME="$LEGACY_MCP_NAME"
		SKILL_NAME="$LEGACY_SKILL_NAME"
		MARKER="$LEGACY_MARKER"
		PATH_MARK="$LEGACY_PATH_MARK"
		MENU_FILE="$LEGACY_MENU_FILE"
		FISH_FILE="$LEGACY_FISH_FILE"
		LABEL="$LEGACY_LABEL"
		UNIT_NAME="$LEGACY_UNIT_NAME"
	else
		SLUG="$CURRENT_SLUG"
		PRODUCT="$CURRENT_PRODUCT"
		APP_NAME="$CURRENT_APP_NAME"
		NODE_NAME="$CURRENT_NODE_NAME"
		MCP_NAME="$CURRENT_MCP_NAME"
		SKILL_NAME="$CURRENT_SKILL_NAME"
		MARKER="$CURRENT_MARKER"
		PATH_MARK="$CURRENT_PATH_MARK"
		MENU_FILE="$CURRENT_MENU_FILE"
		FISH_FILE="$CURRENT_FISH_FILE"
		LABEL="$CURRENT_LABEL"
		UNIT_NAME="$CURRENT_UNIT_NAME"
	fi
	# The desktop binary is named like the app; the release assets carry the
	# slug.
	DESKTOP_NAME="$APP_NAME"
	TREE_NAME="$SLUG"
	CLI_ASSET="${SLUG}_"
	DESKTOP_ASSET="${APP_NAME}_"
}

# legacy_era_of_tag says whether a release tag is from before the rename:
# v0.0.* and v0.1.*, with or without the v. Anything else — v0.2.0, a release
# candidate of it, the dry run's vX.Y.Z placeholder — is current.
legacy_era_of_tag() { # legacy_era_of_tag <tag>
	case "$1" in
	v0.0.* | v0.1.* | 0.0.* | 0.1.*) return 0 ;;
	esac
	return 1
}

# legacy_era_of_archive says whether an archive named on the command line is a
# pre-rename one, by its file name. What it contains is checked once it is
# unpacked (confirm_contents).
legacy_era_of_archive() { # legacy_era_of_archive <file name>
	case "$1" in
	"$LEGACY_SLUG"_* | "$LEGACY_APP_NAME"_*) return 0 ;;
	esac
	return 1
}

usage() {
	cat <<'EOF'
install.sh — install Agent Hallway (desktop app and command line) on macOS or Linux.

  curl -fsSL https://raw.githubusercontent.com/SheldonChangL/agenthub/main/install.sh | sh

Options:
  --version vX.Y.Z   install this release instead of the latest one
                     (AGENTHALLWAY_VERSION, or the older AGENTHUB_VERSION,
                     does the same). Tags up to v0.1.11 install AgentHub, as
                     the product was called then, under its old names
  --cli-only         install ah, agenthallway-node and agenthallway-mcp
                     without the app
  --no-service       do not register the background node
  --no-open          do not open the app when the install finishes (macOS)
  --no-modify-path   do not add ~/.local/bin to PATH in the shell's startup
                     file; only say what to add
  --no-skill         do not install the agenthallway-watch skill for Claude
                     Code (with --uninstall: leave it in place)
  --prefix DIR       install under DIR instead of /Applications or ~/.local;
                     symlinks then go to DIR/bin
  --from FILE        install from a local .dmg or .tar.gz instead of
                     downloading; a SHA256SUMS beside it is still checked
  --uninstall        remove what this script installed, under either name
                     (Agent Hallway, or AgentHub before the rename): the
                     background service, the app, the links, the menu entry,
                     the PATH line and the app's caches; the node's identity
                     and database stay, so a reinstall is the same node
  --purge            with --uninstall: also delete the node's identity,
                     database and log files (only those files: a directory
                     that holds anything else is left), so a reinstall is a
                     new node
  --dry-run          print every command instead of running it
  -h, --help         this text

Through a pipe, flags go after `sh -s --`:

  curl -fsSL https://raw.githubusercontent.com/SheldonChangL/agenthub/main/install.sh | sh -s -- --no-service

It never uses sudo. Read it before you run it: curl -fsSL <url> | less
EOF
}

say() {
	echo "$*"
}

# warn is for something the reader should notice but that is not a refusal. It
# goes to stderr so that it survives a transcript someone is skimming.
warn() {
	echo "warning: $*" >&2
}

die() {
	echo "install.sh: $*" >&2
	exit 1
}

# quote renders one argument the way a shell would have to be given it, so the
# --dry-run transcript is something a reader can paste back. Ordinary words are
# left bare: a transcript in which every word wears quotes is one nobody reads.
quote() {
	case "$1" in
	"" | *[!A-Za-z0-9._/:=@+-]*)
		printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/"
		;;
	*)
		printf '%s' "$1"
		;;
	esac
}

# run is the only place a command with an effect is started. Under --dry-run it
# prints the command and returns 0, which is what makes the dry run safe to
# point at a machine that already has Agent Hallway (or AgentHub) on it.
run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '+'
		for run_argument in "$@"; do
			printf ' %s' "$(quote "$run_argument")"
		done
		printf '\n'
		return 0
	fi
	"$@"
}

cleanup() {
	cleanup_status=$?
	if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
		hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
	fi
	# Both tests matter. An empty TEMP_DIR reaching `rm -rf` is `rm -rf ""`,
	# which some shells expand to the current directory.
	if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
		rm -rf "$TEMP_DIR"
	fi
	exit "$cleanup_status"
}

parse_arguments() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--version)
			[ "$#" -ge 2 ] || die "--version needs a tag, for example --version v0.1.0"
			VERSION="$2"
			shift 2
			;;
		--version=*)
			VERSION="${1#--version=}"
			shift
			;;
		--prefix)
			[ "$#" -ge 2 ] || die "--prefix needs a directory"
			PREFIX="$2"
			shift 2
			;;
		--prefix=*)
			PREFIX="${1#--prefix=}"
			shift
			;;
		--from)
			[ "$#" -ge 2 ] || die "--from needs a path to a .dmg or .tar.gz"
			FROM="$2"
			shift 2
			;;
		--from=*)
			FROM="${1#--from=}"
			shift
			;;
		--cli-only)
			CLI_ONLY=1
			shift
			;;
		--no-service)
			NO_SERVICE=1
			shift
			;;
		--no-open)
			NO_OPEN=1
			shift
			;;
		--no-modify-path)
			NO_MODIFY_PATH=1
			shift
			;;
		--no-skill)
			NO_SKILL=1
			shift
			;;
		--uninstall)
			UNINSTALL=1
			shift
			;;
		--purge)
			PURGE=1
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown option $1; --help lists them"
			;;
		esac
	done
}

# --- the directories this script is allowed to write ---------------------------

# absolute_path makes a path absolute and strips the trailing slashes, so that
# "/", "//" and "/." are one string and can be compared with one test.
absolute_path() {
	absolute_value="$1"
	case "$absolute_value" in
	/*) ;;
	*) absolute_value="$PWD/$absolute_value" ;;
	esac
	while :; do
		case "$absolute_value" in
		/) break ;;
		*/) absolute_value="${absolute_value%/}" ;;
		*) break ;;
		esac
	done
	[ -n "$absolute_value" ] || absolute_value="/"
	printf '%s' "$absolute_value"
}

# exists is -e that also says yes to a symlink whose target is gone; both are
# things that are in the way of an install.
exists() {
	[ -e "$1" ] || [ -L "$1" ]
}

# holds_install asks whether a directory is one an install of this product,
# under either name, already owns. The marker file answers for a prefix this
# script wrote; the binaries answer for a tree installed by hand or by an older
# version of this script.
holds_install() {
	exists "$1/$CURRENT_MARKER" || exists "$1/ah" || exists "$1/bin/ah" ||
		exists "$1/$CURRENT_APP_NAME" || exists "$1/$CURRENT_APP_NAME.app" ||
		exists "$1/share/$CURRENT_SLUG" ||
		exists "$1/$LEGACY_MARKER" || exists "$1/$LEGACY_APP_NAME" ||
		exists "$1/$LEGACY_APP_NAME.app" || exists "$1/share/$LEGACY_SLUG"
}

# check_install_directory refuses a directory this script would delete or
# replace and that is not its own. AGENTHALLWAY_HOME and --prefix are knobs a
# reader is invited to turn, and `rm -rf` is downstream of both.
check_install_directory() { # check_install_directory <what it is> <directory>
	check_dir="$(absolute_path "$2")"
	check_home="$(absolute_path "$HOME")"
	if [ "$check_dir" = "/" ]; then
		die "$1 is /; this script installs into a directory of its own, not into the root of the disk"
	fi
	if [ "$check_dir" = "$check_home" ]; then
		die "$1 is your home directory ($check_dir); installing there would put an upgrade's \`rm -rf\` on it"
	fi
	case "$check_home" in
	"$check_dir"/*)
		die "$1 is $check_dir, which contains your home directory; pick a directory of its own, for example \$HOME/.local/$SLUG"
		;;
	esac
	if [ -d "$check_dir" ] && ! holds_install "$check_dir"; then
		die "$1 is $check_dir, which already exists and holds no $PRODUCT install.
An upgrade replaces that directory, so this script will not take one it did not
create. Pick a new directory, or delete that one yourself first."
	fi
}

# --- verification -------------------------------------------------------------

# digest_of prints the lowercase sha256 of a file.
digest_of() {
	# shellcheck disable=SC2086 # SHA_ARGS is a deliberate word list, and is empty for sha256sum
	"$SHA_CMD" $SHA_ARGS "$1" | cut -d' ' -f1 | tr 'A-F' 'a-f'
}

# verify refuses to go on unless the file's digest is the one the release
# published. This is the only thing standing between a downloader and whatever
# a hostile network handed them, so a missing line in SHA256SUMS is a failure,
# not a shrug.
verify() { # verify <file> <SHA256SUMS path> <name to look up>
	if [ "$DRY_RUN" -eq 1 ]; then
		say "+ $SHA_CMD $SHA_ARGS $1   # compared with $3 in $2, and stop if it differs"
		return 0
	fi
	# Matched field by field rather than with a regular expression built out of
	# a file name: a name is not a pattern, and one with a dot in it matched
	# more lines than the one it names.
	verify_expected="$(awk -v name="$3" '
		length($1) == 64 && $1 ~ /^[0-9a-fA-F]+$/ {
			candidate = $2
			sub(/^\*/, "", candidate)
			if (candidate == name) { print tolower($1); exit }
		}' "$2")"
	[ -n "$verify_expected" ] || die "SHA256SUMS has no line for $3; the download cannot be verified, so nothing was installed"
	verify_actual="$(digest_of "$1")"
	if [ "$verify_actual" != "$verify_expected" ]; then
		die "checksum mismatch for $3
  expected $verify_expected
  got      $verify_actual
Nothing was installed. Delete the file and try again; if it happens twice, do not run it — compare the hash with the one in the release notes at https://github.com/${REPO}/releases"
	fi
	say "verified $3 against SHA256SUMS"
}

fetch() { # fetch <url> <destination>
	if [ -n "$CURL" ]; then
		run "$CURL" -fsSL -o "$2" "$1"
	elif [ -n "$WGET" ]; then
		run "$WGET" -q -O "$2" "$1"
	else
		die "neither curl nor wget is on PATH; install one, or download the release by hand"
	fi
}

resolve_version() {
	if [ -n "$VERSION" ]; then
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		say "+ curl -fsSL $API_LATEST   # to read tag_name"
		VERSION="vX.Y.Z"
		return 0
	fi
	if [ -n "$CURL" ]; then
		resolve_body="$("$CURL" -fsSL "$API_LATEST" 2>/dev/null || true)"
	elif [ -n "$WGET" ]; then
		resolve_body="$("$WGET" -qO- "$API_LATEST" 2>/dev/null || true)"
	else
		die "neither curl nor wget is on PATH; install one, or pass --version vX.Y.Z"
	fi
	# sed rather than jq: a one-line installer that needs a JSON parser
	# installed first is not a one-line installer.
	VERSION="$(printf '%s\n' "$resolve_body" |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	[ -n "$VERSION" ] || die "could not read the latest version from $API_LATEST; pass --version vX.Y.Z, or check https://github.com/${REPO}/releases"
	say "latest release is $VERSION"
}

# --- install ------------------------------------------------------------------

# link_into puts one symlink in BIN_DIR, replacing whatever was there, so a
# second run of this script is an upgrade rather than an error.
link_into() { # link_into <target> <name>
	run ln -sfn "$1" "$BIN_DIR/$2"
	say "linked $BIN_DIR/$2 -> $1"
}

# startup_file names the file a new terminal of this owner's login shell reads,
# which is where a PATH line has to go to be seen, or prints nothing for a
# shell whose files this does not know how to write (csh, nu, ...). zsh has
# been the macOS default since 10.15. Terminal opens a bash as a login shell,
# which reads only the first of .bash_profile, .bash_login and .profile that
# exists — so the line goes into that one, because creating a .bash_profile
# beside an existing .profile would silently switch the .profile off. On Linux
# a terminal's bash reads .bashrc.
startup_file() {
	case "$(basename "${SHELL:-}")" in
	zsh) echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
	bash)
		if [ "$OS_SLUG" = "darwin" ]; then
			for bash_login_file in .bash_profile .bash_login .profile; do
				if [ -e "$HOME/$bash_login_file" ]; then
					echo "$HOME/$bash_login_file"
					return 0
				fi
			done
			echo "$HOME/.bash_profile"
		else
			echo "$HOME/.bashrc"
		fi
		;;
	fish) echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/$FISH_FILE" ;;
	"")
		if [ "$OS_SLUG" = "darwin" ]; then
			echo "${ZDOTDIR:-$HOME}/.zshrc"
		else
			echo "$HOME/.profile"
		fi
		;;
	sh | dash | ash | ksh | mksh | yash) echo "$HOME/.profile" ;;
	esac
}

# path_file_marked says whether one startup file carries the comment this
# script writes above its PATH line, under either name: the pre-rename
# installer wrote "# added by the AgentHub installer", and an upgrade that did
# not recognise it would add a second PATH line.
path_file_marked() { # path_file_marked <file>
	[ -f "$1" ] && { grep -qF "$CURRENT_PATH_MARK" "$1" || grep -qF "$LEGACY_PATH_MARK" "$1"; }
}

# path_already_added says whether the startup file already carries the lines
# this script appends, and sets PATH_ADDED_IN to the file that does. For fish
# the lines live in a file of their own, whose name changed with the product,
# so both names are looked at.
path_already_added() { # path_already_added <startup file>
	PATH_ADDED_IN="$1"
	path_file_marked "$1" && return 0
	case "$1" in
	*.fish)
		for added_fish in "$CURRENT_FISH_FILE" "$LEGACY_FISH_FILE"; do
			PATH_ADDED_IN="$(dirname "$1")/$added_fish"
			path_file_marked "$PATH_ADDED_IN" && return 0
		done
		;;
	esac
	return 1
}

# ensure_path makes `ah` something a new terminal finds. macOS puts no
# ~/.local/bin on PATH at all, so without this the one-line install ends with
# a command that is not found. It appends one marked line to the shell's
# startup file, once; a --prefix install and --no-modify-path only say what to
# add, because an owner who chose either has chosen to manage PATH themselves.
ensure_path() {
	PATH_STATE="on PATH"
	case ":${PATH}:" in
	*":$BIN_DIR:"*) return 0 ;;
	esac
	PATH_HINT="note: $BIN_DIR is not on your PATH. Add it: export PATH=\"$BIN_DIR:\$PATH\""
	if [ -n "$PREFIX" ] || [ "$NO_MODIFY_PATH" -eq 1 ]; then
		say "$PATH_HINT"
		PATH_STATE="not on PATH; add $BIN_DIR to it"
		return 0
	fi
	PATH_FILE="$(startup_file)"
	if [ -z "$PATH_FILE" ]; then
		say "$PATH_HINT (this script does not write $(basename "$SHELL")'s startup files)"
		PATH_STATE="not on PATH; add $BIN_DIR to it"
		return 0
	fi
	case "$PATH_FILE" in
	*.fish)
		# shellcheck disable=SC2016 # written for fish to expand, not this shell
		path_line='contains -- $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH'
		;;
	*)
		# shellcheck disable=SC2016 # written for the startup file to expand
		path_line='export PATH="$HOME/.local/bin:$PATH"'
		;;
	esac
	if path_already_added "$PATH_FILE"; then
		say "$PATH_ADDED_IN already adds $BIN_DIR to PATH"
	elif [ "$DRY_RUN" -eq 1 ]; then
		printf '+ append to %s: %s\n' "$(quote "$PATH_FILE")" "$path_line"
	# The app is already in place when this runs, and the service is not yet
	# registered, so a startup file that cannot be written (a read-only
	# symlink, as home-manager makes them) is a warning and not the end of the
	# install: under set -e a failed append would exit here, leaving the node
	# unregistered and — on Linux — stopped.
	elif (mkdir -p "$(dirname "$PATH_FILE")" && printf '\n%s\n%s\n' "$PATH_MARK" "$path_line" >>"$PATH_FILE") 2>/dev/null; then
		say "added $BIN_DIR to PATH in $PATH_FILE"
	else
		warn "could not write $PATH_FILE, so $BIN_DIR is not on your PATH. Add it: export PATH=\"$BIN_DIR:\$PATH\""
		PATH_STATE="not on PATH; add $BIN_DIR to it"
		return 0
	fi
	PATH_STATE="on PATH in new terminals (this one: export PATH=\"$BIN_DIR:\$PATH\")"
}

# unpack_tarball extracts into the temp directory and prints nothing; the
# unpacked directory lands in UNPACKED.
unpack_tarball() {
	run mkdir -p "$TEMP_DIR/unpacked"
	run tar -xzf "$ARCHIVE" -C "$TEMP_DIR/unpacked"
	UNPACKED=""
	for unpack_candidate in "$TEMP_DIR/unpacked"/*; do
		if [ -d "$unpack_candidate" ]; then
			UNPACKED="$unpack_candidate"
			break
		fi
	done
	if [ -z "$UNPACKED" ]; then
		if [ "$DRY_RUN" -eq 1 ]; then
			# Nothing was really extracted, so name the directory the release
			# puts inside the archive and carry on printing.
			UNPACKED="$TEMP_DIR/unpacked/$(basename "$ARCHIVE_NAME" .tar.gz)"
		else
			die "$ARCHIVE_NAME did not contain a directory; it is not an $PRODUCT archive"
		fi
	fi
}

# era_label names a release era the way the refusals below say it.
era_label() { # era_label <current|legacy>
	if [ "$1" = legacy ]; then
		printf '%s' "a pre-rename $LEGACY_PRODUCT release (v0.1.11 or earlier)"
	else
		printf '%s' "an $CURRENT_PRODUCT release (v0.2.0 or later)"
	fi
}

# confirm_contents checks that what was unpacked or mounted is the era its name
# said, before anything is replaced: the names decide which install is retired
# and which unit is registered, so an archive renamed by hand must not get as
# far as either. Under --dry-run nothing was unpacked, so there is nothing to
# look at.
confirm_contents() { # confirm_contents <path that must exist> <path the other era has>
	[ "$DRY_RUN" -eq 0 ] || return 0
	exists "$1" && return 0
	if [ "$ERA" = legacy ]; then
		contents_other="$(era_label current)"
	else
		contents_other="$(era_label legacy)"
	fi
	if exists "$2"; then
		die "the archive name says $ARCHIVE_NAME is $(era_label "$ERA"), but it contains $(basename "$2"), which is $contents_other; nothing was installed"
	fi
	die "the archive name says $ARCHIVE_NAME is $(era_label "$ERA"), but it contains no $(basename "$1"); nothing was installed"
}

# prepare_tarball unpacks the archive into the temp directory and checks it,
# before anything installed is stopped or replaced.
prepare_tarball() {
	check_install_directory "the $PRODUCT directory" "$TREE"
	unpack_tarball
	if [ "$ERA" = legacy ]; then
		confirm_contents "$UNPACKED/$NODE_NAME" "$UNPACKED/$CURRENT_NODE_NAME"
	else
		confirm_contents "$UNPACKED/$NODE_NAME" "$UNPACKED/$LEGACY_NODE_NAME"
	fi
}

# mount_dmg attaches the disk image and checks it, before any app is quit or
# replaced.
mount_dmg() {
	MOUNT_POINT="$TEMP_DIR/mnt"
	run mkdir -p "$MOUNT_POINT"
	run hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MOUNT_POINT" "$ARCHIVE"
	if [ "$ERA" = legacy ]; then
		confirm_contents "$MOUNT_POINT/$APP_NAME.app" "$MOUNT_POINT/$CURRENT_APP_NAME.app"
	else
		confirm_contents "$MOUNT_POINT/$APP_NAME.app" "$MOUNT_POINT/$LEGACY_APP_NAME.app"
	fi
}

# replace_directory swaps a directory for a freshly unpacked one. The old one is
# unlinked rather than written into: on Linux, writing over the binary of a
# running node fails with "text file busy", and the running node keeps its own
# already-open copy until the service is restarted below.
replace_directory() { # replace_directory <staging> <destination>
	run mkdir -p "$(dirname "$2")"
	run rm -rf "$2"
	run mv "$1" "$2"
}

# quit_running_app asks a running desktop app to quit before its bundle is
# deleted from under it. Replacing the bundle of a running process leaves the
# process alive with no files: menus stop working, and the next launch is from
# a bundle the old process still half-owns.
#
# osascript asks by name, and any app of that name would hear it, so it is
# only asked when that very bundle's executable is running.
quit_running_app() { # quit_running_app <app bundle> <app name>
	quit_app="$1"
	quit_name="$2"
	[ -n "$quit_app" ] || return 0
	if ! command -v pgrep >/dev/null 2>&1; then
		return 0
	fi
	if ! pgrep -f "$quit_app/Contents/MacOS/desktop" >/dev/null 2>&1; then
		return 0
	fi
	say "$quit_name is running; asking it to quit before its bundle is removed"
	if [ "$DRY_RUN" -eq 1 ]; then
		run osascript -e "quit app \"$quit_name\""
		return 0
	fi
	# The answer osascript gives is not the answer to "did it quit". This app
	# (Wails, with no OnBeforeClose veto: desktop/main.go sets only OnStartup)
	# replies to every quit request with "cancel" and then quits on its own
	# a moment later (its applicationShouldTerminate: returns NSTerminateCancel
	# and hands the quit to its Go side), so AppleScript reports error -128,
	# "user canceled", for a quit that is in fact under way. Under set -e that
	# reply ended the install with a raw AppleScript line and no next step
	# (issue #211). Whether the process is gone is what pgrep says below; the
	# reply is kept only to be shown if it never goes.
	quit_reply=""
	if ! quit_reply="$(osascript -e "quit app \"$quit_name\"" 2>&1)"; then
		[ -n "$quit_reply" ] || quit_reply="osascript failed without saying why"
	else
		quit_reply=""
	fi
	quit_waited=0
	while [ "$quit_waited" -lt 10 ]; do
		if ! pgrep -f "$quit_app/Contents/MacOS/desktop" >/dev/null 2>&1; then
			say "$quit_name quit"
			return 0
		fi
		sleep 1
		quit_waited=$((quit_waited + 1))
	done
	if [ -n "$quit_reply" ]; then
		die "$quit_name is still running after 10 seconds, and removing a running app's bundle breaks it.
Quit it yourself (right-click its Dock icon, Quit) and run this again.
(macOS answered the quit request with: $quit_reply)"
	fi
	die "$quit_name is still running after 10 seconds, and removing a running app's bundle breaks it.
Quit it yourself (right-click its Dock icon, Quit) and run this again."
}

# quit_legacy_apps asks a running pre-rename app to quit before the upgrade
# takes its background service away (and, unless that service stays, its
# bundle): a pre-rename window left running could start a pre-rename node of
# its own on the files the new node is about to move.
quit_legacy_apps() {
	quit_running_app "$LEGACY_APP_PATH" "$LEGACY_APP_NAME"
	quit_running_app "$LEGACY_OTHER_APP_PATH" "$LEGACY_APP_NAME"
}

install_macos_app() {
	run mkdir -p "$APP_PARENT"
	quit_running_app "$APP_PATH" "$APP_NAME"
	run rm -rf "$APP_PATH"
	run ditto "$MOUNT_POINT/$APP_NAME.app" "$APP_PATH"
	# The skill is copied out before the image is detached; installing it waits
	# for install_claude_skill, like the tarball's. Under --dry-run nothing is
	# mounted, so the copy is printed as if the image carried one.
	if [ "$NO_SKILL" -eq 0 ] && { [ "$DRY_RUN" -eq 1 ] || [ -f "$MOUNT_POINT/$DMG_SKILL_DIR/$SKILL_NAME/SKILL.md" ]; }; then
		run mkdir -p "$TEMP_DIR/dmg-skill"
		run cp -R "$MOUNT_POINT/$DMG_SKILL_DIR/$SKILL_NAME" "$TEMP_DIR/dmg-skill/$SKILL_NAME"
		SKILL_SOURCE="$TEMP_DIR/dmg-skill/$SKILL_NAME"
	fi
	run hdiutil detach "$MOUNT_POINT" -quiet
	MOUNT_POINT=""
	say "installed $APP_PATH"
	# Legitimate here, and only here: Gatekeeper's quarantine prompt exists to
	# ask "is this file what its publisher built?", and this script has just
	# answered that question with the release's own SHA256SUMS — a stronger
	# check than the one being skipped, done before a single byte was unpacked.
	# The app is not notarized (issue #66), so without this the first launch is
	# a dialog and a trip through System Settings for a file already proven.
	if [ "$DRY_RUN" -eq 1 ]; then
		run xattr -dr com.apple.quarantine "$APP_PATH"
	else
		xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
		say "cleared the quarantine flag (the digest above is what Gatekeeper would have stood in for)"
	fi
	AH="$APP_PATH/Contents/MacOS/ah"
	link_into "$AH" "ah"
}

install_tarball_tree() {
	replace_directory "$UNPACKED" "$TREE"
	say "installed $TREE"
	AH="$TREE/ah"
	link_into "$AH" "ah"
	SKILL_SOURCE="$TREE/skills/$SKILL_NAME"
	if [ "$CLI_ONLY" -eq 1 ]; then
		link_into "$TREE/$NODE_NAME" "$NODE_NAME"
		link_into "$TREE/$MCP_NAME" "$MCP_NAME"
	else
		link_into "$TREE/$DESKTOP_NAME" "$DESKTOP_NAME"
	fi
}

# detect_webkit_abi reports which WebKit2GTK this machine can actually load.
#
# The Linux app binds WebKit through cgo, and WebKit2GTK ships as two ABIs that
# are not interchangeable: 4.1 is the libsoup3 build, 4.0 the libsoup2 one. A
# binary linked against either exits immediately on a machine that has only the
# other — "libwebkit2gtk-4.1.so.0: cannot open shared object file", no window,
# nothing in any log. Ubuntu 22.04 and its derivatives normally have 4.0
# installed; Ubuntu 24.04, Debian 13 and Fedora 39+ have 4.1.
#
# Some distributions can install the other ABI as well (22.04 has
# libwebkit2gtk-4.1-0 in jammy-updates/universe), so this is not about which
# runtime is obtainable — it is about which one is already there. Installing a
# package needs root, and this script never asks for it, so the only build that
# can start without a password is the one matching what is installed now.
#
# So the release builds Linux twice and this chooses the download. Reading
# ldconfig rather than /etc/os-release on purpose: what matters is the library
# that is installed, not the distribution that usually installs it, and a
# machine that has been upgraded, has a backport, or is a derivative nobody
# listed answers correctly here and would not from a name.
#
# ldconfig itself is the trap. It lives in /sbin, and /sbin is not on a
# non-root PATH on Debian and its derivatives, which is exactly the population
# running `curl ... | sh` as themselves on a 4.0 machine. `command -v ldconfig`
# misses there, so the absolute paths are tried too; a probe that gives up
# because of where a binary lives would silently take the 4.1 archive on the
# distribution this whole mechanism exists for.
#
# Sets WEBKIT_ABI to 4.1, 4.0, or empty when neither was found, and
# WEBKIT_PROBED to 1 when some ldconfig answered at all and 0 when none could
# be run (musl, NixOS, a stripped PATH). Empty with WEBKIT_PROBED=0 means "not
# known", which is a different thing from "not installed" and is reported as
# such rather than passed off as a diagnosis.
detect_webkit_abi() {
	WEBKIT_ABI=""
	WEBKIT_PROBED=0
	webkit_libs=""
	# AGENTHALLWAY_LDCONFIG_PATHS exists so the "no ldconfig reachable" and "only at
	# an absolute path" branches can be tested on a machine that has a real
	# ldconfig in /sbin, which no PATH the tests control can hide. Same reason as
	# AGENTHALLWAY_OS_RELEASE above it: the branch that matters is the one the test
	# machine is least likely to be in.
	for webkit_ldconfig in ${AGENTHALLWAY_LDCONFIG_PATHS:-ldconfig /sbin/ldconfig /usr/sbin/ldconfig}; do
		case "$webkit_ldconfig" in
		/*) [ -x "$webkit_ldconfig" ] || continue ;;
		*) command -v "$webkit_ldconfig" >/dev/null 2>&1 || continue ;;
		esac
		webkit_libs="$("$webkit_ldconfig" -p 2>/dev/null || true)"
		[ -n "$webkit_libs" ] || continue
		WEBKIT_PROBED=1
		break
	done
	[ "$WEBKIT_PROBED" -eq 1 ] || return 0
	# 4.1 first. On the rare machine carrying both, it is the one still getting
	# security updates everywhere it ships.
	case "$webkit_libs" in
	*libwebkit2gtk-4.1.so.0*)
		case "$webkit_libs" in
		*libwebkit2gtk-4.0.so.37*) WEBKIT_ABI="both" ;;
		*) WEBKIT_ABI="4.1" ;;
		esac
		return 0
		;;
	esac
	case "$webkit_libs" in
	*libwebkit2gtk-4.0.so.37*)
		WEBKIT_ABI="4.0"
		return 0
		;;
	esac
	return 0
}

# webkit_hint says what to install when neither ABI is present. With one of them
# installed there is nothing to say: the matching build was downloaded, and the
# app starts.
webkit_hint() {
	[ -z "$WEBKIT_ABI" ] || return 0
	# AGENTHALLWAY_OS_RELEASE exists so the branches below can be tested. Which
	# package name this prints is the whole value of the hint — it is read by
	# someone whose app will not start — and the names do not follow a pattern
	# (4.1 is libwebkit2gtk-4.1-0, 4.0 is libwebkit2gtk-4.0-37), so a wrong one
	# is both easy to write and impossible to notice from the machine that
	# happens to be running the tests.
	webkit_os_release="${AGENTHALLWAY_OS_RELEASE:-/etc/os-release}"
	webkit_id=""
	if [ -r "$webkit_os_release" ]; then
		webkit_id="$(sed -n 's/^ID_LIKE=//p;' "$webkit_os_release" | tr -d '"' | head -n 1)"
		if [ -z "$webkit_id" ]; then
			webkit_id="$(sed -n 's/^ID=//p' "$webkit_os_release" | tr -d '"' | head -n 1)"
		fi
	fi
	if [ "${WEBKIT_PROBED:-0}" -eq 1 ]; then
		say "warning: no WebKit2GTK runtime was found, so the window will not open yet."
	else
		# Nothing was probed, so nothing is known — but staying quiet is worse
		# than saying so. The runtime may well be there; what is certain is
		# which archive was taken, and that is what gets said.
		say "warning: this machine's WebKit2GTK could not be read (no readable ldconfig),"
		say "         so the window may not open."
	fi
	say "         The 4.1 build was installed; install its runtime if it is missing:"
	case "$webkit_id" in
	*debian* | *ubuntu*) say "  sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0" ;;
	*fedora* | *rhel*) say "  sudo dnf install gtk3 webkit2gtk4.1" ;;
	*arch*) say "  sudo pacman -S gtk3 webkit2gtk-4.1" ;;
	*) say "  install GTK 3 and WebKit2GTK 4.1 with your package manager (the README.txt beside the app names the package)" ;;
	esac
	say "         If your distribution has only the older 4.0 runtime, install"
	say "         that instead and re-run this script: it will pick the 4.0 build."
}

# install_desktop_entry puts the app in the applications menu.
#
# Without it the app is installed and runnable and invisible: someone who just
# installed a desktop application looks for it in their launcher, not in a
# terminal. Written per-user under XDG_DATA_HOME — the rest of this script
# installs per-user and never sudo, and a menu entry is not the place to start.
#
# Icon= is the absolute path of the icon inside the install tree rather than a
# themed name, so there is no hicolor directory to populate and no icon cache to
# refresh; both are extra steps that fail quietly on a minimal desktop.
install_desktop_entry() {
	[ "$OS_SLUG" = "linux" ] || return 0
	[ "$CLI_ONLY" -eq 0 ] || return 0

	desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
	desktop_file="$desktop_dir/$MENU_FILE"
	desktop_exec="$TREE/$DESKTOP_NAME"
	desktop_icon="$TREE/appicon.png"

	run mkdir -p "$desktop_dir"
	if [ "$DRY_RUN" -eq 1 ]; then
		say "+ write $desktop_file"
	else
		# The icon is only named when it is really there: a .desktop entry
		# pointing Icon= at a missing file shows a broken-image placeholder in
		# some launchers, which looks worse than the generic icon they use when
		# the key is absent. Archives from before the icon shipped land here.
		# Exec= is quoted. The desktop-entry spec parses the value as a command
		# line, so an unquoted path under a $HOME with a space in it ("/home/Ann
		# Lee/.local/...") is read as a program plus an argument and the entry
		# launches nothing. Quoting is spec-conformant for any path, so it is
		# unconditional rather than a check nobody's machine would exercise.
		cat >"$desktop_file" <<DESKTOP_ENTRY
[Desktop Entry]
Type=Application
Name=$PRODUCT
Comment=Local control plane for coding-agent sessions
Exec="$desktop_exec"
Terminal=false
Categories=Development;
StartupWMClass=$DESKTOP_NAME
DESKTOP_ENTRY
		if [ -f "$desktop_icon" ]; then
			echo "Icon=$desktop_icon" >>"$desktop_file"
		fi
		say "wrote $desktop_file"
	fi

	# Best effort: the entry is valid the moment it is written, and every
	# desktop environment picks it up on the next login regardless. This only
	# saves the owner that login, so its absence is not worth a warning.
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
	fi
}

# stop_linux_node stops the running node before its directory is replaced, so an
# upgrade does not leave systemd supervising a binary that no longer exists at
# that path. It is best effort: nothing installed means nothing to stop.
#
# The pre-rename unit runs a node from the pre-rename tree, which an upgrade
# does not replace, so it is left running — `ah service install` retires it in
# order, with its database carried over — except when both names share one
# tree (an AGENTHUB_HOME install upgraded in place), whose binaries are about to
# be swapped from under it.
stop_linux_node() {
	if ! command -v systemctl >/dev/null 2>&1; then
		return 0
	fi
	stop_units="$UNIT_NAME"
	if [ "$UNIT_NAME" != "$LEGACY_UNIT_NAME" ] && [ "$(absolute_path "$TREE")" = "$(absolute_path "$LEGACY_TREE")" ]; then
		stop_units="$UNIT_NAME $LEGACY_UNIT_NAME"
	fi
	for stop_unit in $stop_units; do
		if systemctl --user is-active --quiet "$stop_unit.service" 2>/dev/null; then
			say "stopping the running node ($stop_unit) before replacing its binaries"
			run systemctl --user stop "$stop_unit.service"
		fi
	done
}

# --- the Claude Code skill ------------------------------------------------------

# skill_directory is where Claude Code looks for a user-level skill.
skill_directory() { # skill_directory [skill name]
	printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/${1:-$SKILL_NAME}"
}

# skill_is_ours says yes only to a real directory holding the marker this
# script writes (the given one: each name's skill carries its own name's
# marker). A symlink is never ours, whatever it points at: it is how an owner
# who keeps skills elsewhere wires them in.
skill_is_ours() { # skill_is_ours <directory> [marker]
	[ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/${2:-$MARKER}" ]
}

# install_claude_skill puts the agent's skill where Claude Code finds it,
# so an agent on this machine knows `ah` is there to be used. It copies from the
# asset that was just verified and unpacked — never from the network — and
# replaces only a copy this script put there before. Nothing about it is worth
# failing an install over: the app is in place, and a skill that could not be
# written is a warning with the path to fix.
install_claude_skill() {
	if [ "$NO_SKILL" -eq 1 ]; then
		say "skipped the Claude Code skill (--no-skill)"
		SKILL_STATE="not installed (--no-skill)"
		return 0
	fi
	skill_dest="$(skill_directory)"
	# Under --dry-run nothing was unpacked, so the source cannot be looked at;
	# print what a release that carries the skill would get.
	if [ -z "$SKILL_SOURCE" ] || { [ "$DRY_RUN" -eq 0 ] && [ ! -f "$SKILL_SOURCE/SKILL.md" ]; }; then
		warn "this release does not carry the $SKILL_NAME skill for Claude Code (releases before it do not), so none was installed; everything else was"
		SKILL_STATE="not installed (this release does not carry it)"
		return 0
	fi
	# A --prefix install writes nothing outside the prefix, for the same reason
	# it leaves the shell's startup files alone: an owner who chose where
	# everything goes has chosen to wire it up themselves.
	if [ -n "$PREFIX" ]; then
		say "skipped the Claude Code skill: a --prefix install writes nothing outside $PREFIX"
		SKILL_STATE="not installed (--prefix writes nothing outside $PREFIX)"
		return 0
	fi
	if exists "$skill_dest" && ! skill_is_ours "$skill_dest"; then
		say "left $skill_dest alone: it is not a copy this script installed (a link or a copy of your own)"
		SKILL_STATE="$skill_dest is your own; left as it is"
		return 0
	fi
	skill_stage="$TEMP_DIR/skill-stage/$SKILL_NAME"
	if run mkdir -p "$TEMP_DIR/skill-stage" &&
		run cp -R "$SKILL_SOURCE" "$skill_stage" &&
		run touch "$skill_stage/$MARKER" &&
		run mkdir -p "$(dirname "$skill_dest")" &&
		run rm -rf "$skill_dest" &&
		run mv "$skill_stage" "$skill_dest"; then
		say "installed the Claude Code skill $skill_dest"
		SKILL_STATE="$skill_dest (Claude Code sessions started from now on load it; running ones do not)"
	else
		warn "could not install the Claude Code skill into $skill_dest; everything else was installed"
		SKILL_STATE="not installed (could not write $skill_dest)"
	fi
}

# --- the background service ---------------------------------------------------

# status_ah names the ah to ask about the current registration: the one just
# installed, or — under --dry-run, where nothing was installed — whatever ah is
# already on PATH, which is the build that wrote the unit being asked about.
status_ah() {
	if [ -n "$AH" ] && [ -x "$AH" ]; then
		printf '%s' "$AH"
		return 0
	fi
	command -v ah 2>/dev/null || true
}

# read_service_registration reads the unit that is registered now.
#
# `ah service install` replaces an existing registration outright, and the
# database path is not remembered anywhere else: a reinstall that does not
# carry --db forward writes a unit with no --db, the node then opens its
# default database, and the machine comes back with a new identity, no
# pairings and no history. Nothing on screen would say so. So this is read
# first, and when it cannot be read the service is not touched at all.
#
# Sets SERVICE_READ (1 when the answer is trustworthy), SERVICE_INSTALLED,
# SERVICE_DB and SERVICE_EXTRA (other node flags the unit carries).
read_service_registration() {
	SERVICE_READ=0
	SERVICE_INSTALLED=0
	SERVICE_DB=""
	SERVICE_EXTRA=""
	service_ah="$(status_ah)"
	if [ -z "$service_ah" ]; then
		# No ah anywhere to ask, which is also no unit anywhere to preserve.
		SERVICE_READ=1
		return 0
	fi
	service_json="$("$service_ah" --json service status 2>/dev/null || true)"
	service_flat="$(printf '%s' "$service_json" | tr '\n\t' '  ')"
	service_installed="$(printf '%s' "$service_flat" |
		sed -n 's/.*"Installed"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')"
	case "$service_installed" in
	true) SERVICE_INSTALLED=1 ;;
	false) SERVICE_INSTALLED=0 ;;
	# Anything else is a command that failed, an older ah with no --json, or
	# output this does not understand. Not "no service": unknown.
	*) return 0 ;;
	esac
	SERVICE_READ=1
	service_args="$(printf '%s' "$service_flat" |
		sed -n 's/.*"Arguments"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')"
	SERVICE_DB="$(printf '%s' "$service_args" |
		sed -n 's/.*"-*db"[[:space:]]*,[[:space:]]*"\([^"]*\)".*/\1/p')"
	if [ -z "$SERVICE_DB" ]; then
		SERVICE_DB="$(printf '%s' "$service_args" |
			sed -n 's/.*"-*db=\([^"]*\)".*/\1/p')"
	fi
	SERVICE_EXTRA="$(printf '%s' "$service_args" | tr ',' '\n' |
		sed -n 's/.*"--\([a-z][a-z-]*\)".*/--\1/p' |
		grep -v '^--db$' | grep -v '^--node-binary$' | tr '\n' ' ')"
}

register_service() {
	read_service_registration
	if [ "$SERVICE_READ" -eq 0 ]; then
		warn "could not read the current background service from \"$(status_ah)\"."
		say "The app is installed, but the background node was left alone: registering it"
		say "blind would re-point an existing node at a different database, and that node"
		say "would come back with a new identity and no pairings. Register it yourself:"
		say ""
		say "  \"$AH\" service install --db <path to the node's database>"
		say ""
		say "The unit file names the database it uses now: \"$AH\" service status"
		SERVICE_STATE="not registered; run \"$AH\" service install --db <path to the node's database>"
		return 0
	fi
	say "registering the background node"
	if [ "$SERVICE_INSTALLED" -eq 1 ] && [ -n "$SERVICE_DB" ]; then
		say "keeping the node's database at $SERVICE_DB"
		say "note: the unit's node binary is replaced on purpose — it now points at the one just installed"
		if [ -n "$SERVICE_EXTRA" ]; then
			warn "the old unit also carried ${SERVICE_EXTRA}; those are not carried over. The node remembers its network settings in its database (\`ah settings set ...\`), or pass them to \`ah service install\` yourself."
		fi
		run "$AH" service install --db "$SERVICE_DB"
	else
		run "$AH" service install
	fi
	SERVICE_REGISTERED=1
	run "$AH" service status
	SERVICE_STATE="running as a background service (\"$AH\" service status shows it)"
}

# --- what the reader is left with ----------------------------------------------

closing_lines() {
	say ""
	if [ -n "$VERSION" ]; then
		say "done. $PRODUCT $VERSION is installed:"
	else
		say "done. $PRODUCT is installed:"
	fi
	if [ "$INSTALLED_APP" -eq 1 ]; then
		say "  app:  $APP_PATH"
	fi
	if [ "$INSTALLED_TREE" -eq 1 ]; then
		say "  files: $TREE"
	fi
	say "  ah:   $BIN_DIR/ah   (\"$AH --version\" says which build)"
	say "  PATH: $PATH_STATE"
	say "  node: $SERVICE_STATE"
	say "  skill: $SKILL_STATE"
	if [ -n "$LEGACY_STATE" ]; then
		say "  pre-rename install: $LEGACY_STATE"
	fi
	say ""
	if [ "$CLI_ONLY" -eq 0 ]; then
		if [ "$OS_SLUG" = "darwin" ] && [ "$INSTALLED_APP" -eq 1 ] && [ -z "$PREFIX" ]; then
			say "Open $APP_NAME from Applications; it starts on a setup checklist."
		elif [ "$OS_SLUG" = "darwin" ] && [ "$INSTALLED_APP" -eq 1 ]; then
			say "Open $APP_PATH; it starts on a setup checklist."
		else
			say "Open $DESKTOP_NAME ($BIN_DIR/$DESKTOP_NAME); it starts on a setup checklist."
		fi
	fi
	say "To pass flags through the pipe, put them after \`sh -s --\`:"
	say "  curl -fsSL $RAW_SELF | sh -s -- --no-service"
}

# --- uninstall, and retiring the pre-rename install ------------------------------

# Everything below removes only what this script (or `ah service install`, or
# the app, or the node) put in place, and each removal checks that the thing is
# ours first: a symlink is removed only when it points into an install, a
# directory only when it holds one, and inside a data or log directory only a
# file with a name the node writes. The owner's own files are never the
# collateral of a pattern that happened to match.

# remove_path deletes one file or directory when it exists, and says so.
remove_path() { # remove_path <path>
	if exists "$1"; then
		# Removing an entry needs its directory writable: /Applications after an
		# account stopped being an admin is the case. Under set -e a failing rm
		# would end the uninstall halfway; this says what is left instead.
		if [ ! -w "$(dirname "$1")" ]; then
			warn "could not remove $1: $(dirname "$1") is not writable by this account; delete it yourself (from Finder, or with an administrator's help)"
			REMOVE_SKIPPED="$REMOVE_SKIPPED $1"
			return 0
		fi
		run rm -rf "$1"
		[ "$DRY_RUN" -eq 1 ] || say "removed $1"
	fi
}

# remove_file deletes one file or symlink, and never a directory: it is what
# works inside a directory this product shares with others (a data directory,
# a log directory, ~/.local/bin), where nothing is ours by being in there.
remove_file() { # remove_file <path>
	exists "$1" || return 0
	if [ -d "$1" ] && [ ! -L "$1" ]; then
		say "left $1 alone: it is a directory, and only a file of that name is $CURRENT_PRODUCT's"
		return 0
	fi
	if [ ! -w "$(dirname "$1")" ]; then
		warn "could not remove $1: $(dirname "$1") is not writable by this account; delete it yourself"
		REMOVE_SKIPPED="$REMOVE_SKIPPED $1"
		return 0
	fi
	run rm -f "$1"
	[ "$DRY_RUN" -eq 1 ] || say "removed $1"
}

# link_points_into says whether <link> is a symlink whose target is inside one
# of the given install locations. An empty location matches nothing: as a
# pattern it would be "/*", which is every absolute path.
link_points_into() { # link_points_into <link> <install location>...
	[ -L "$1" ] || return 1
	points_target="$(readlink "$1" 2>/dev/null || true)"
	[ -n "$points_target" ] || return 1
	shift
	for points_dir in "$@"; do
		[ -n "$points_dir" ] || continue
		case "$points_target" in
		"$points_dir"/*) return 0 ;;
		esac
	done
	return 1
}

# remove_link deletes BIN_DIR/<name> when it is a symlink into one of the given
# install locations. A real file, or a link to some other ah (a source build,
# say), is left alone.
remove_link() { # remove_link <name> <install location>...
	link_path="$BIN_DIR/$1"
	shift
	[ -L "$link_path" ] || return 0
	if link_points_into "$link_path" "$@"; then
		remove_file "$link_path"
	else
		say "left $link_path alone: it points at $(readlink "$link_path" 2>/dev/null || true), not at this install"
	fi
}

# install_ah_era says which name's ah sits in a directory: the node beside it
# says, since an AGENTHUB_HOME tree upgraded in place holds either. Prints
# legacy or current.
install_ah_era() { # install_ah_era <directory holding ah> <legacy|current: what the location suggests>
	if exists "$1/$CURRENT_NODE_NAME"; then
		printf current
	elif exists "$1/$LEGACY_NODE_NAME"; then
		printf legacy
	else
		printf '%s' "$2"
	fi
}

# pick_uninstall_ah sets AH to one of this install's own ah, and nothing else,
# and AH_ERA to which name's it is: a current ah takes down both registrations,
# a pre-rename one only its own. An ah found on PATH could be a source build,
# or the real install when this run is a --prefix one, and what it would take
# down is its own service, not this one.
pick_uninstall_ah() {
	AH=""
	AH_ERA=""
	for pick_dir in "${APP_PATH:+$APP_PATH/Contents/MacOS}" "${OTHER_APP_PATH:+$OTHER_APP_PATH/Contents/MacOS}" "$TREE" \
		"${LEGACY_APP_PATH:+$LEGACY_APP_PATH/Contents/MacOS}" "${LEGACY_OTHER_APP_PATH:+$LEGACY_OTHER_APP_PATH/Contents/MacOS}" "$LEGACY_TREE"; do
		[ -n "$pick_dir" ] || continue
		if [ -x "$pick_dir/ah" ]; then
			AH="$pick_dir/ah"
			case "$pick_dir" in
			"${LEGACY_APP_PATH:-/nonexistent-app-path}"/* | "${LEGACY_OTHER_APP_PATH:-/nonexistent-app-path}"/*) AH_ERA=legacy ;;
			"$LEGACY_TREE") AH_ERA="$(install_ah_era "$pick_dir" legacy)" ;;
			*) AH_ERA="$(install_ah_era "$pick_dir" current)" ;;
			esac
			return 0
		fi
	done
}

# unit_file_for is where `ah service install` writes a registration: a launchd
# plist named by its label, or a systemd user unit.
unit_file_for() { # unit_file_for <launchd label> <systemd unit name>
	if [ "$OS_SLUG" = "darwin" ]; then
		printf '%s' "$HOME/Library/LaunchAgents/$1.plist"
	else
		printf '%s' "$HOME/.config/systemd/user/$2.service"
	fi
}

# unit_file is this run's own registration, current_unit_file the one under
# the current names (whichever release this run installs), legacy_unit_file
# the one a pre-rename ah wrote.
unit_file() {
	unit_file_for "$LABEL" "$UNIT_NAME"
}
current_unit_file() {
	unit_file_for "$CURRENT_LABEL" "$CURRENT_UNIT_NAME"
}
legacy_unit_file() {
	unit_file_for "$LEGACY_LABEL" "$LEGACY_UNIT_NAME"
}

# physical_path prints a path with its directory resolved the way the node
# records it: `ah service install` writes os.Executable's answer, which is
# symlink-free on Linux and has no doubled or trailing slashes. The directory
# must exist; a path whose directory does not is printed as given.
physical_path() { # physical_path <path>
	physical_dir="$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)" || physical_dir=""
	if [ -n "$physical_dir" ]; then
		printf '%s/%s' "$physical_dir" "$(basename "$1")"
	else
		printf '%s' "$1"
	fi
}

# xml_escape spells a string the way Go's xml.EscapeText does, which is how
# the launchd plist writer puts each argument inside <string>.
xml_escape() { # xml_escape <string>
	xml_tab="$(printf '\t')"
	printf '%s' "$1" | sed "s/&/\\&amp;/g; s/</\\&lt;/g; s/>/\\&gt;/g; s/\"/\\&#34;/g; s/'/\\&#39;/g; s/$xml_tab/\\&#x9;/g"
}

# node_forms prints, one per line, every way a unit can spell each given node
# binary: as given and resolved, each as launchd writes it (XML-escaped inside
# <string>) and as systemd does (% doubled; quoted, with \ " $ escaped, when the
# path needs it — internal/service SystemdUnit). Each form line is preceded by
# the node path it spells, after a tab, so a match can say which node it was.
node_forms() { # node_forms <node binary>...
	for forms_node in "$@"; do
		[ -n "$forms_node" ] || continue
		for forms_path in "$forms_node" "$(physical_path "$forms_node")"; do
			forms_xml="$(xml_escape "$forms_path")"
			printf '<string>%s</string>\n' "$forms_xml"
			forms_pct="$(printf '%s' "$forms_path" | sed 's/%/%%/g')"
			# systemdQuote quotes a path holding a space, tab, quote, \ or $.
			if printf '%s' "$forms_pct" | grep -q '[[:space:]"'"'"'\\$]'; then
				forms_quoted="$(printf '%s' "$forms_pct" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/$$/g')"
				printf 'ExecStart="%s"\n' "$forms_quoted"
			else
				printf 'ExecStart=%s\n' "$forms_pct"
			fi
		done
	done
}

# service_is_ours says yes when the given unit starts one of the given node
# binaries. There is one registration per user and name whoever made it — a
# source checkout's bin/ah, the real install while this is a --prefix run — so
# the unit's own program is the only thing that says whose it is. Read from the
# file rather than through `ah`, which may be gone or be someone else's.
service_is_ours() { # service_is_ours <unit file> <node binary>...
	ours_unit="$1"
	shift
	[ -f "$ours_unit" ] || return 1
	node_forms "$@" >"$TEMP_DIR/node-forms"
	while IFS= read -r ours_form; do
		case "$ours_form" in
		"<string>"*)
			grep -qF "$ours_form" "$ours_unit" 2>/dev/null && return 0
			;;
		*)
			# The first word of ExecStart: followed by a space, or the whole line.
			grep -qF "$ours_form " "$ours_unit" 2>/dev/null && return 0
			grep -qxF "$ours_form" "$ours_unit" 2>/dev/null && return 0
			;;
		esac
	done <"$TEMP_DIR/node-forms"
	return 1
}

# unit_mentions_install says yes when the given unit names one of the given
# directories in any form. A unit that does and still is not recognised as
# ours is one this script cannot read — and deleting the files a registered
# service runs from is the one outcome these checks exist to prevent.
unit_mentions_install() { # unit_mentions_install <unit file> <directory>...
	mention_unit="$1"
	shift
	for mention_dir in "$@"; do
		[ -n "$mention_dir" ] || continue
		for mention_form in "$mention_dir" "$(physical_path "$mention_dir")"; do
			grep -qF "$mention_form/" "$mention_unit" 2>/dev/null && return 0
			grep -qF "$(xml_escape "$mention_form")/" "$mention_unit" 2>/dev/null && return 0
		done
	done
	return 1
}

# The node binaries and directories of every install this run may remove: the
# current names' app bundles and tree, and the pre-rename ones'. On Linux the
# app paths are empty (see main), so they match nothing.
unit_is_any_install() { # unit_is_any_install <unit file>
	service_is_ours "$1" \
		"${APP_PATH:+$APP_PATH/Contents/MacOS/$CURRENT_NODE_NAME}" \
		"${OTHER_APP_PATH:+$OTHER_APP_PATH/Contents/MacOS/$CURRENT_NODE_NAME}" \
		"$TREE/$CURRENT_NODE_NAME" \
		"${LEGACY_APP_PATH:+$LEGACY_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
		"${LEGACY_OTHER_APP_PATH:+$LEGACY_OTHER_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
		"$LEGACY_TREE/$LEGACY_NODE_NAME"
}
unit_mentions_any_install() { # unit_mentions_any_install <unit file>
	unit_mentions_install "$1" "$APP_PATH" "$OTHER_APP_PATH" "$TREE" \
		"$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH" "$LEGACY_TREE"
}

# classify_unit sets UNIT_STATE for one registration file: absent, ours (it
# starts one of the installs this run removes) or foreign. A unit that names a
# path inside those installs without starting one of their nodes in a form
# this script can read stops the uninstall before anything is removed.
classify_unit() { # classify_unit <unit file>
	UNIT_STATE=absent
	exists "$1" || return 0
	if unit_is_any_install "$1"; then
		UNIT_STATE=ours
		return 0
	fi
	if unit_mentions_any_install "$1"; then
		die "$1 names a path inside this install, but not in a form this script can read as starting this install's node, so nothing was removed: deleting what a registered service runs from leaves it failing at every login. Take the service down first (\"ah service uninstall\" with the ah it was registered by), then run this again."
	fi
	UNIT_STATE=foreign
	say "left the registered background service alone: $1 starts a node that is not this install's"
}

# take_down_unit stops a registration and removes its file directly, the way
# `ah service uninstall` would: for an install half-removed by hand, whose ah
# is gone, or for the current registration when only a pre-rename ah is left.
take_down_unit() { # take_down_unit <unit file> <launchd label> <systemd unit name>
	case "$OS_SLUG" in
	darwin) run launchctl bootout "gui/$(id -u)/$2" || true ;;
	linux) run systemctl --user disable --now "$3.service" || true ;;
	esac
	remove_path "$1"
	if [ "$OS_SLUG" = "linux" ]; then
		run systemctl --user daemon-reload || true
	fi
}

# remove_services stops the node and removes its registrations, before any
# file they run from is deleted: launchd and systemd both restart a node that
# exits, and one pointed at a binary that is gone fails in a loop at every
# login. A current ah takes down both names' registrations in one command
# (internal/service Uninstall), so it is used only when neither of them is
# someone else's; a pre-rename ah knows only its own.
remove_services() {
	if [ "$SERVICE_OURS" -eq 0 ]; then
		return 0
	fi
	if [ "$AH_ERA" = current ] && [ "$CURRENT_UNIT_STATE" != foreign ] && [ "$LEGACY_UNIT_STATE" != foreign ]; then
		if ! run "$AH" service uninstall; then
			die "\"$AH\" service uninstall failed, so nothing else was removed: deleting the app under a registered service leaves it failing at every login. Fix that first, then run this again."
		fi
		return 0
	fi
	if [ "$AH_ERA" = legacy ] && [ "$LEGACY_UNIT_STATE" = ours ]; then
		if ! run "$AH" service uninstall; then
			die "\"$AH\" service uninstall failed, so nothing else was removed: deleting the app under a registered service leaves it failing at every login. Fix that first, then run this again."
		fi
	elif [ "$LEGACY_UNIT_STATE" = ours ]; then
		take_down_unit "$(legacy_unit_file)" "$LEGACY_LABEL" "$LEGACY_UNIT_NAME"
	fi
	if [ "$CURRENT_UNIT_STATE" = ours ]; then
		take_down_unit "$(current_unit_file)" "$CURRENT_LABEL" "$CURRENT_UNIT_NAME"
	fi
}

# stop_window_node stops a node the desktop window started on its own (it does
# that when no service is running) — a detached process the service manager
# knows nothing about, still holding the database open — and on Linux the
# window itself. Matched by the full path of each given binary, so no other
# node is touched.
stop_window_node() { # stop_window_node <binary>...
	command -v pkill >/dev/null 2>&1 || return 0
	for window_node in "$@"; do
		[ -n "$window_node" ] || continue
		if pgrep -f "$window_node" >/dev/null 2>&1; then
			run pkill -f "$window_node" || true
			say "stopped $window_node"
		fi
	done
}

# unpath_file takes the lines ensure_path appended back out of one startup
# file, under either name's comment: the comment, the line under it when it is
# the one this script wrote, and the blank line it put above them. The rest of
# the file is rewritten byte for byte, in place — through `cat >`, so a
# symlinked file stays a link. A fish file holding the comment is this
# script's whole.
unpath_file() { # unpath_file <file>
	[ -f "$1" ] || return 0
	if grep -qF "$CURRENT_PATH_MARK" "$1" 2>/dev/null; then
		unpath_mark="$CURRENT_PATH_MARK"
	elif grep -qF "$LEGACY_PATH_MARK" "$1" 2>/dev/null; then
		unpath_mark="$LEGACY_PATH_MARK"
	else
		return 0
	fi
	if ! grep -qxF "$CURRENT_PATH_MARK" "$1" 2>/dev/null && ! grep -qxF "$LEGACY_PATH_MARK" "$1" 2>/dev/null; then
		warn "$1 mentions \"$unpath_mark\" but not as the line this script writes; left it as it is"
		return 0
	fi
	case "$1" in
	*/fish/conf.d/"$CURRENT_FISH_FILE" | */fish/conf.d/"$LEGACY_FISH_FILE")
		remove_path "$1"
		return 0
		;;
	esac
	if [ "$DRY_RUN" -eq 1 ]; then
		say "+ remove the $CURRENT_PRODUCT PATH lines from $(quote "$1")"
		return 0
	fi
	# shellcheck disable=SC2016 # the literal line ensure_path writes
	unpath_line='export PATH="$HOME/.local/bin:$PATH"'
	unpath_tmp="$TEMP_DIR/startup-file"
	awk -v mark="$CURRENT_PATH_MARK" -v legacy_mark="$LEGACY_PATH_MARK" -v line="$unpath_line" '
		skip { skip = 0; if ($0 == line) next }
		$0 == mark || $0 == legacy_mark { held = 0; skip = 1; next }
		{
			if (held) print ""
			held = 0
			if ($0 == "") { held = 1; next }
			print
		}
		END { if (held) print "" }' "$1" >"$unpath_tmp"
	if (cat "$unpath_tmp" >"$1") 2>/dev/null; then
		say "removed the $CURRENT_PRODUCT PATH lines from $1"
	else
		warn "could not write $1; remove the \"$unpath_mark\" line and the one under it yourself"
	fi
}

# default_data_directory is where the node keeps node.key and its database
# when nothing says otherwise: os.UserConfigDir()/agenthallway, and before the
# rename os.UserConfigDir()/agenthub, which the node moves its own files out
# of on its first start after the upgrade (internal/datadir).
default_data_directory() { # default_data_directory [slug]
	if [ "$OS_SLUG" = "darwin" ]; then
		printf '%s' "$HOME/Library/Application Support/${1:-$SLUG}"
	else
		printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/${1:-$SLUG}"
	fi
}

# log_directory is where the node started by the service (macOS) or by the
# window writes node.log. Logs are not moved by the upgrade: the pre-rename
# directory keeps the old ones.
log_directory() { # log_directory [slug]
	if [ "$OS_SLUG" = "darwin" ]; then
		printf '%s' "$HOME/Library/Logs/${1:-$SLUG}"
	else
		printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/${1:-$SLUG}"
	fi
}

# our_data_file says whether a file name in a data directory is one the node
# writes there (internal/datadir lists them): its key, the temporary file a
# key is written through, its database under either name with SQLite's
# companions, the move's marker, and the database the service unit names.
# Nothing is ours by being in the directory: on macOS the pre-rename one is
# also, case-insensitively, the directory of an unrelated app called AgentHub.
our_data_file() { # our_data_file <file name>
	case "$1" in
	node.key | .node.key-* | "$LEGACY_MIGRATION_MARK") return 0 ;;
	esac
	for our_db in "$CURRENT_DB_NAME" "$LEGACY_DB_NAME" "${PURGE_DB_NAME:-$CURRENT_DB_NAME}"; do
		case "$1" in
		"$our_db" | "$our_db-wal" | "$our_db-shm" | "$our_db-journal") return 0 ;;
		esac
	done
	return 1
}

# leave_or_rmdir removes a directory this product made once nothing is left in
# it, and otherwise says what kept it. rmdir, never rm -rf: what is left is not
# this product's to delete. Under --dry-run nothing was removed, so the files
# the commands above would have removed are not counted as left.
leave_or_rmdir() { # leave_or_rmdir <directory> <data|log>
	[ -d "$1" ] || return 0
	if [ -L "$1" ]; then
		say "left $1: it is a symbolic link, not a directory this script made"
		return 0
	fi
	left_names=""
	left_count=0
	for left_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
		exists "$left_entry" || continue
		left_name="$(basename "$left_entry")"
		if [ "$DRY_RUN" -eq 1 ] && { [ ! -d "$left_entry" ] || [ -L "$left_entry" ]; }; then
			if [ "$2" = data ] && our_data_file "$left_name"; then
				continue
			fi
			if [ "$2" = log ] && [ "$left_name" = node.log ]; then
				continue
			fi
		fi
		left_count=$((left_count + 1))
		if [ "$left_count" -le 5 ]; then
			left_names="${left_names:+$left_names, }$left_name"
		fi
	done
	if [ "$left_count" -eq 0 ]; then
		if run rmdir "$1" 2>/dev/null; then
			[ "$DRY_RUN" -eq 1 ] || say "removed $1"
		else
			warn "could not remove the empty directory $1"
		fi
		return 0
	fi
	[ "$left_count" -le 5 ] || left_names="$left_names, …"
	say "left $1: it holds files that are not $CURRENT_PRODUCT's ($left_names)"
}

# remove_our_files deletes, from one data directory, the files the node
# writes there (our_data_file) and nothing else, then the directory if that
# emptied it.
remove_our_files() { # remove_our_files <directory>
	[ -d "$1" ] || return 0
	for our_entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
		exists "$our_entry" || continue
		if our_data_file "$(basename "$our_entry")"; then
			remove_file "$our_entry"
		fi
	done
	leave_or_rmdir "$1" data
}

# data_directories prints, one per line and each once, the directories --purge
# looks in: the one beside the database the registered unit names, the
# current default and the pre-rename default.
data_directories() {
	data_seen=""
	data_service_dir=""
	[ -z "$SERVICE_DB" ] || data_service_dir="$(dirname "$SERVICE_DB")"
	for data_dir in "$data_service_dir" "$(default_data_directory "$CURRENT_SLUG")" "$(default_data_directory "$LEGACY_SLUG")"; do
		[ -n "$data_dir" ] || continue
		data_abs="$(absolute_path "$data_dir")"
		if printf '%s\n' "$data_seen" | grep -qxF "$data_abs"; then
			continue
		fi
		data_seen="$data_seen
$data_abs"
		printf '%s\n' "$data_dir"
	done
}

# purge_data deletes the node's identity, history and logs: the files the node
# writes, from each directory it may have written them to, and each directory
# only once that leaves it empty. Never a directory whole — the pre-rename data
# directory on macOS is, case-insensitively, also another product's, and a
# database the owner kept in ./data of a checkout has neighbours of its own.
purge_data() {
	# The data a registered service belongs to is only this install's to
	# delete when the service is. A --prefix run with no service of its own
	# would otherwise take the default directory, which is the real node's.
	if [ "$SERVICE_OURS" -eq 0 ] && { [ -n "$PREFIX" ] || [ "$SERVICE_FOUND" -eq 1 ]; }; then
		say "left the node's identity and database alone: the node they belong to is not this install's"
		PURGED=0
		return 0
	fi
	PURGED=1
	if [ "$SERVICE_READ" -eq 0 ]; then
		warn "the registered service could not be read, so a database kept somewhere other than $(default_data_directory "$CURRENT_SLUG") or $(default_data_directory "$LEGACY_SLUG") was not looked for"
	fi
	PURGE_DB_NAME=""
	[ -z "$SERVICE_DB" ] || PURGE_DB_NAME="$(basename "$SERVICE_DB")"
	data_directories >"$TEMP_DIR/data-directories"
	while IFS= read -r purge_dir; do
		# The unit's own database file name counts only in the directory the
		# unit names; elsewhere a file of that name is someone else's.
		purge_db_name_kept="$PURGE_DB_NAME"
		if [ -n "$SERVICE_DB" ] && [ "$(absolute_path "$purge_dir")" != "$(absolute_path "$(dirname "$SERVICE_DB")")" ]; then
			PURGE_DB_NAME=""
		fi
		remove_our_files "$purge_dir"
		PURGE_DB_NAME="$purge_db_name_kept"
	done <"$TEMP_DIR/data-directories"
	for purge_log in "$(log_directory "$CURRENT_SLUG")" "$(log_directory "$LEGACY_SLUG")"; do
		[ -d "$purge_log" ] || continue
		remove_file "$purge_log/node.log"
		leave_or_rmdir "$purge_log" log
	done
}

# kept_data_directories names the directories that hold a node.key, for the
# closing line of an uninstall that keeps them.
kept_data_directories() {
	kept_list=""
	data_directories >"$TEMP_DIR/data-directories"
	while IFS= read -r kept_dir; do
		if exists "$kept_dir/node.key"; then
			kept_list="${kept_list:+$kept_list and }$kept_dir"
		fi
	done <"$TEMP_DIR/data-directories"
	printf '%s' "${kept_list:-$(default_data_directory "$CURRENT_SLUG")}"
}

# is_install_tree says yes to a directory that is an unpacked tree of this
# product, under either name, and not a place that merely has one in it: ah
# and a node binary at its top level, and none of the directories install
# refuses to use. holds_install is looser on purpose — it recognises a prefix
# — and a source checkout, which has bin/ah, passes it.
is_install_tree() { # is_install_tree <directory>
	tree_dir="$(absolute_path "$1")"
	tree_home="$(absolute_path "$HOME")"
	[ "$tree_dir" != "/" ] || return 1
	[ "$tree_dir" != "$tree_home" ] || return 1
	case "$tree_home" in "$tree_dir"/*) return 1 ;; esac
	# A checkout with both binaries built at its root (`go build ./cmd/ah`)
	# has them too; its go.mod or .git says what it is.
	if exists "$tree_dir/go.mod" || exists "$tree_dir/.git"; then
		return 1
	fi
	[ -f "$tree_dir/ah" ] && { [ -f "$tree_dir/$CURRENT_NODE_NAME" ] || [ -f "$tree_dir/$LEGACY_NODE_NAME" ]; }
}

# looks_like_app says yes to an app bundle of this product.
looks_like_app() { # looks_like_app <path>
	exists "$1/Contents/MacOS/ah" || exists "$1/Contents/MacOS/desktop"
}

# menu_entry_launches says whether a .desktop file starts the given binary.
# Entries from before Exec= was quoted spell it bare.
menu_entry_launches() { # menu_entry_launches <entry> <binary>
	[ -f "$1" ] || return 1
	grep -qxF "Exec=\"$2\"" "$1" 2>/dev/null || grep -qxF "Exec=$2" "$1" 2>/dev/null
}

# bundle_id_of reads an app bundle's CFBundleIdentifier, which names its caches
# and preferences under ~/Library, or prints the given default.
bundle_id_of() { # bundle_id_of <app bundle> <default>
	bundle_read=""
	if [ -f "$1/Contents/Info.plist" ]; then
		bundle_read="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true)"
	fi
	printf '%s' "${bundle_read:-$2}"
}

# app_caches prints the paths under ~/Library that an app with this bundle id
# writes: caches, WebKit storage (the window's preferences live there),
# preferences and saved window state.
app_caches() { # app_caches <bundle id>
	for cache_entry in "Caches/$1" "WebKit/$1" "HTTPStorages/$1" "Preferences/$1.plist" "Saved Application State/$1.savedState"; do
		printf '%s\n' "$HOME/Library/$cache_entry"
	done
}

# --- the pre-rename install, after an upgrade ------------------------------------

# legacy_item collects one thing retire_legacy_install found (list) or removes
# it (remove). A link is a file in a directory of the owner's; everything else
# is a directory or file of the pre-rename install's own.
legacy_item() { # legacy_item <list|remove> <path> [file]
	if [ "$1" = list ]; then
		LEGACY_FOUND="${LEGACY_FOUND:+$LEGACY_FOUND, }$2"
	elif [ "${3:-}" = file ]; then
		remove_file "$2"
	else
		remove_path "$2"
	fi
}

# legacy_inventory walks what a pre-rename install put in place and is still
# there, in the order it is removed: links, then app bundles, the tree, the
# menu entry, the skill, the app's caches and the prefix marker. Each is
# looked at the way --uninstall looks at it: a link only when it points into
# the pre-rename app or tree, the tree only when it is one, the skill only
# when it carries the pre-rename marker. Never data, logs, PATH lines or the
# pre-rename fish file — those still put ~/.local/bin on PATH, and the data is
# the node's to move.
legacy_inventory() { # legacy_inventory <list|remove>
	for inventory_name in "$LEGACY_NODE_NAME" "$LEGACY_MCP_NAME" "$LEGACY_APP_NAME"; do
		if link_points_into "$BIN_DIR/$inventory_name" "$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH" "$LEGACY_TREE"; then
			legacy_item "$1" "$BIN_DIR/$inventory_name" file
		fi
	done
	for inventory_app in "$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH"; do
		if [ -n "$inventory_app" ] && looks_like_app "$inventory_app"; then
			legacy_item "$1" "$inventory_app"
		fi
	done
	# An AGENTHUB_HOME tree is the current tree as well, upgraded in place.
	if [ "$(absolute_path "$LEGACY_TREE")" != "$(absolute_path "$TREE")" ] && is_install_tree "$LEGACY_TREE"; then
		legacy_item "$1" "$LEGACY_TREE"
	fi
	inventory_entry="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$LEGACY_MENU_FILE"
	if menu_entry_launches "$inventory_entry" "$LEGACY_TREE/$LEGACY_APP_NAME"; then
		legacy_item "$1" "$inventory_entry" file
	fi
	if [ "$NO_SKILL" -eq 0 ] && [ -z "$PREFIX" ]; then
		inventory_skill="$(skill_directory "$LEGACY_SKILL_NAME")"
		if skill_is_ours "$inventory_skill" "$LEGACY_MARKER"; then
			legacy_item "$1" "$inventory_skill"
		fi
	fi
	if [ "$OS_SLUG" = "darwin" ] && [ -z "$PREFIX" ]; then
		app_caches "$LEGACY_BUNDLE_ID" >"$TEMP_DIR/legacy-caches"
		while IFS= read -r inventory_cache; do
			if exists "$inventory_cache"; then
				legacy_item "$1" "$inventory_cache"
			fi
		done <"$TEMP_DIR/legacy-caches"
	fi
	if [ -n "$PREFIX" ] && exists "$PREFIX/$LEGACY_MARKER"; then
		legacy_item "$1" "$PREFIX/$LEGACY_MARKER" file
	fi
}

# retire_legacy_install removes the pre-rename install that an upgrade has
# just replaced: its app, tree, links, menu entry, marked skill and caches.
#
# Not while a pre-rename registration that runs them is still in place: the
# old node would fail at every login, and — worse — a launchd job with
# KeepAlive restarting it would find its identity moved away and make a new
# one. `ah service install` from the new release retires that registration
# (internal/service), which is why this runs after register_service; with
# --no-service, or a service that could not be read, the old install stays and
# the reader is told what to run. Under --dry-run nothing was registered, so a
# registration the printed `ah service install` would retire counts as gone.
retire_legacy_install() {
	LEGACY_FOUND=""
	legacy_inventory list
	[ -n "$LEGACY_FOUND" ] || return 0
	retire_unit="$(legacy_unit_file)"
	if exists "$retire_unit" && ! { [ "$DRY_RUN" -eq 1 ] && [ "$SERVICE_REGISTERED" -eq 1 ]; }; then
		if service_is_ours "$retire_unit" \
			"${LEGACY_APP_PATH:+$LEGACY_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
			"${LEGACY_OTHER_APP_PATH:+$LEGACY_OTHER_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
			"$LEGACY_TREE/$LEGACY_NODE_NAME" ||
			unit_mentions_install "$retire_unit" "$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH" "$LEGACY_TREE"; then
			warn "the pre-rename background service $retire_unit is still registered and runs the pre-rename install; the old install was kept so it keeps working. \"$AH\" service install replaces it (and keeps its database); run this script again afterwards."
			LEGACY_STATE="kept, because its background service is still registered: $LEGACY_FOUND"
			return 0
		fi
	fi
	stop_window_node \
		"${LEGACY_APP_PATH:+$LEGACY_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
		"${LEGACY_OTHER_APP_PATH:+$LEGACY_OTHER_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
		"$LEGACY_TREE/$LEGACY_NODE_NAME" "$LEGACY_TREE/$LEGACY_APP_NAME"
	retire_skipped="$REMOVE_SKIPPED"
	legacy_inventory remove
	if [ "$DRY_RUN" -eq 1 ]; then
		say "the commands above remove the pre-rename $LEGACY_PRODUCT install: $LEGACY_FOUND"
		LEGACY_STATE="removed: $LEGACY_FOUND"
	elif [ "$REMOVE_SKIPPED" != "$retire_skipped" ]; then
		LEGACY_STATE="partly removed; delete what is left yourself:${REMOVE_SKIPPED#"$retire_skipped"}"
	else
		say "removed the pre-rename $LEGACY_PRODUCT install: $LEGACY_FOUND"
		LEGACY_STATE="removed: $LEGACY_FOUND"
	fi
}

# legacy_era_guard stops a pre-rename release from being installed over a
# machine that has moved on. The pre-rename node looks for its identity in
# the pre-rename data directory; once the new node has moved it, a pre-rename
# node registered the usual way would start as a new node with no pairings.
# With --no-service nothing is registered, so the install goes ahead and the
# reader gets the commands that run the old node on the moved files.
legacy_era_guard() {
	[ "$ERA" = legacy ] || return 0
	guard_found=""
	guard_data="$(default_data_directory "$CURRENT_SLUG")"
	for guard_file in node.key "$CURRENT_DB_NAME" "$LEGACY_MIGRATION_MARK"; do
		if exists "$guard_data/$guard_file"; then
			guard_found="${guard_found:+$guard_found, }$guard_data/$guard_file"
		fi
	done
	guard_unit="$(current_unit_file)"
	if exists "$guard_unit"; then
		guard_found="${guard_found:+$guard_found, }$guard_unit"
	fi
	guard_ah=""
	for guard_app in "$CURRENT_APP_PATH" "$CURRENT_OTHER_APP_PATH"; do
		if [ -n "$guard_app" ] && looks_like_app "$guard_app"; then
			guard_found="${guard_found:+$guard_found, }$guard_app"
			[ -n "$guard_ah" ] || guard_ah="$guard_app/Contents/MacOS/ah"
		fi
	done
	if exists "$CURRENT_TREE/$CURRENT_NODE_NAME"; then
		guard_found="${guard_found:+$guard_found, }$CURRENT_TREE"
		[ -n "$guard_ah" ] || guard_ah="$CURRENT_TREE/ah"
	fi
	[ -n "$guard_found" ] || return 0
	guard_tag="${VERSION:-$ARCHIVE_NAME}"
	guard_recipe="To run the pre-rename node on the identity the new node moved (a rollback):
  \"${guard_ah:-ah}\" service uninstall
  curl -fsSL $RAW_SELF | sh -s -- --version ${VERSION:-<tag>} --no-service
  \"$BIN_DIR/ah\" service install --db \"$guard_data/$CURRENT_DB_NAME\"
The first removes the $CURRENT_PRODUCT registration (and data stays where it is);
the last registers the pre-rename node on the moved database, so it is the same
node. Never move the files back by hand while any node runs."
	if [ "$NO_SERVICE" -eq 1 ]; then
		warn "$guard_tag is from before the rename to $CURRENT_PRODUCT, and this machine has moved on ($guard_found). It is installed because of --no-service, and nothing is registered.
$guard_recipe"
		return 0
	fi
	die "$guard_tag is from before the rename to $CURRENT_PRODUCT. This machine already has $CURRENT_PRODUCT ($guard_found): installed here, $guard_tag would register a node that looks for its identity in $(default_data_directory "$LEGACY_SLUG"), which the new node moves to $guard_data, and it would start as a new node. Nothing was installed. Either install v0.2.0 or later, or roll back.
$guard_recipe"
}

# warn_stale_mcp_configs names the MCP configurations that still start the
# pre-rename agenthub-mcp, which an upgrade has just removed. Read-only: these
# files are the owner's (~/.claude.json is rewritten by every running Claude
# Code), and an entry cannot be told from another product's by its key. An
# entry is ours when its command is the pre-rename MCP binary.
warn_stale_mcp_configs() {
	stale=""
	stale_seen=""
	for stale_file in "${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}" "$HOME/.claude.json" "${CODEX_HOME:-$HOME/.codex}/config.toml"; do
		[ -n "$stale_file" ] || continue
		case "$stale_seen" in
		*"|$stale_file|"*) continue ;;
		esac
		stale_seen="$stale_seen|$stale_file|"
		if [ -f "$stale_file" ] && grep -qF "$LEGACY_MCP_NAME" "$stale_file" 2>/dev/null; then
			stale="$stale $stale_file"
		fi
	done
	[ -n "$stale" ] || return 0
	# The one this run installed: it sits beside ah in the app and the tree.
	stale_replacement="$CURRENT_MCP_NAME"
	if [ -n "$AH" ]; then
		stale_replacement="$(dirname "$AH")/$CURRENT_MCP_NAME"
	fi
	warn "these still start $LEGACY_MCP_NAME, which this upgrade removed:$stale. Replace that entry with one keyed $CURRENT_SLUG whose command is $stale_replacement and whose arguments are the old entry's (-as <provider>:<id>, plus -url or -channel if it had them); the tools are now mcp__${CURRENT_SLUG}__*. Project .mcp.json files were not searched."
}

# --- uninstall -------------------------------------------------------------------

uninstall() {
	TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$CURRENT_SLUG-uninstall.XXXXXX")"
	trap cleanup EXIT INT TERM HUP

	pick_uninstall_ah
	CURRENT_UNIT_STATE=absent
	LEGACY_UNIT_STATE=absent
	classify_unit "$(current_unit_file)"
	CURRENT_UNIT_STATE="$UNIT_STATE"
	classify_unit "$(legacy_unit_file)"
	LEGACY_UNIT_STATE="$UNIT_STATE"
	SERVICE_FOUND=0
	if [ "$CURRENT_UNIT_STATE" != absent ] || [ "$LEGACY_UNIT_STATE" != absent ]; then
		SERVICE_FOUND=1
	fi
	SERVICE_OURS=0
	if [ "$CURRENT_UNIT_STATE" = ours ] || [ "$LEGACY_UNIT_STATE" = ours ]; then
		SERVICE_OURS=1
	fi
	SERVICE_READ=0
	SERVICE_DB=""
	# Read before the service goes: the unit is the only record of a database
	# kept somewhere other than the default, and --purge needs to know where.
	# Only through this install's own ah, only for a unit that is ours, and
	# only when that ah reads the unit that is ours: a current ah describes
	# the current registration (or, with none, the pre-rename one), a
	# pre-rename ah only the pre-rename one.
	if [ -n "$AH" ] && [ "$SERVICE_OURS" -eq 1 ]; then
		if { [ "$AH_ERA" = current ] && [ "$CURRENT_UNIT_STATE" != foreign ]; } ||
			{ [ "$AH_ERA" = legacy ] && [ "$LEGACY_UNIT_STATE" = ours ]; }; then
			read_service_registration
		fi
	elif [ "$SERVICE_FOUND" -eq 0 ]; then
		SERVICE_READ=1
	fi
	uninstall_bundle_ids=""
	if [ "$OS_SLUG" = "darwin" ]; then
		for uninstall_app in "$APP_PATH" "$OTHER_APP_PATH"; do
			if [ -n "$uninstall_app" ] && looks_like_app "$uninstall_app"; then
				uninstall_bundle_ids="$uninstall_bundle_ids $(bundle_id_of "$uninstall_app" "$CURRENT_BUNDLE_ID")"
			fi
		done
		for uninstall_app in "$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH"; do
			if [ -n "$uninstall_app" ] && looks_like_app "$uninstall_app"; then
				uninstall_bundle_ids="$uninstall_bundle_ids $(bundle_id_of "$uninstall_app" "$LEGACY_BUNDLE_ID")"
			fi
		done
		uninstall_bundle_ids="$uninstall_bundle_ids $CURRENT_BUNDLE_ID $LEGACY_BUNDLE_ID"
	fi

	remove_services
	if [ "$OS_SLUG" = "darwin" ]; then
		quit_running_app "$APP_PATH" "$CURRENT_APP_NAME"
		quit_running_app "$OTHER_APP_PATH" "$CURRENT_APP_NAME"
		quit_running_app "$LEGACY_APP_PATH" "$LEGACY_APP_NAME"
		quit_running_app "$LEGACY_OTHER_APP_PATH" "$LEGACY_APP_NAME"
	fi
	stop_window_node \
		"${APP_PATH:+$APP_PATH/Contents/MacOS/$CURRENT_NODE_NAME}" \
		"${OTHER_APP_PATH:+$OTHER_APP_PATH/Contents/MacOS/$CURRENT_NODE_NAME}" \
		"$TREE/$CURRENT_NODE_NAME" "$TREE/$CURRENT_APP_NAME" \
		"${LEGACY_APP_PATH:+$LEGACY_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
		"${LEGACY_OTHER_APP_PATH:+$LEGACY_OTHER_APP_PATH/Contents/MacOS/$LEGACY_NODE_NAME}" \
		"$LEGACY_TREE/$LEGACY_NODE_NAME" "$LEGACY_TREE/$LEGACY_APP_NAME"

	for uninstall_name in ah "$CURRENT_NODE_NAME" "$CURRENT_MCP_NAME" "$CURRENT_APP_NAME" \
		"$LEGACY_NODE_NAME" "$LEGACY_MCP_NAME" "$LEGACY_APP_NAME"; do
		remove_link "$uninstall_name" "$APP_PATH" "$OTHER_APP_PATH" "$TREE" \
			"$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH" "$LEGACY_TREE"
	done
	for uninstall_app in "$APP_PATH" "$OTHER_APP_PATH" "$LEGACY_APP_PATH" "$LEGACY_OTHER_APP_PATH"; do
		if [ -z "$uninstall_app" ]; then
			:
		elif looks_like_app "$uninstall_app"; then
			remove_path "$uninstall_app"
		elif exists "$uninstall_app"; then
			say "left $uninstall_app alone: it does not look like the $CURRENT_PRODUCT app"
		fi
	done
	for uninstall_tree in "$TREE" "$LEGACY_TREE"; do
		[ -d "$uninstall_tree" ] || continue
		if is_install_tree "$uninstall_tree"; then
			remove_path "$uninstall_tree"
		else
			say "left $uninstall_tree alone: it is not an unpacked $CURRENT_PRODUCT install"
		fi
	done
	if [ -n "$PREFIX" ]; then
		remove_path "$PREFIX/$CURRENT_MARKER"
		remove_path "$PREFIX/$LEGACY_MARKER"
	fi

	# A --prefix install never put one there, so a --prefix uninstall does not
	# go looking. Each name's skill carries its own name's marker.
	if [ "$NO_SKILL" -eq 0 ] && [ -z "$PREFIX" ]; then
		for uninstall_skill_pair in "$CURRENT_SKILL_NAME $CURRENT_MARKER" "$LEGACY_SKILL_NAME $LEGACY_MARKER"; do
			uninstall_skill="$(skill_directory "${uninstall_skill_pair% *}")"
			if skill_is_ours "$uninstall_skill" "${uninstall_skill_pair#* }"; then
				remove_path "$uninstall_skill"
			elif exists "$uninstall_skill"; then
				say "left $uninstall_skill alone: it is not a copy this script installed"
			fi
		done
	fi

	# A menu entry is this install's when it launches this install's app; one
	# written by a --prefix install and one by the real install share the same
	# file name.
	for uninstall_entry_pair in "$CURRENT_MENU_FILE|$TREE/$CURRENT_APP_NAME" "$LEGACY_MENU_FILE|$LEGACY_TREE/$LEGACY_APP_NAME"; do
		uninstall_entry="${XDG_DATA_HOME:-$HOME/.local/share}/applications/${uninstall_entry_pair%%|*}"
		if menu_entry_launches "$uninstall_entry" "${uninstall_entry_pair#*|}"; then
			remove_path "$uninstall_entry"
		elif [ -f "$uninstall_entry" ]; then
			say "left $uninstall_entry alone: it launches some other install"
		fi
	done

	# A --prefix install never writes a startup file or has caches of its own
	# (they are named by bundle id, and the real install's are the same ones),
	# so a --prefix uninstall leaves both alone.
	uninstall_fish_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
	[ -n "$PREFIX" ] || for uninstall_rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bash_profile" "$HOME/.bash_login" \
		"$HOME/.profile" "$HOME/.bashrc" "$uninstall_fish_dir/$CURRENT_FISH_FILE" "$uninstall_fish_dir/$LEGACY_FISH_FILE"; do
		unpath_file "$uninstall_rc"
	done

	if [ "$OS_SLUG" = "darwin" ] && [ -z "$PREFIX" ]; then
		uninstall_ids_seen=""
		# shellcheck disable=SC2086 # a list of bundle ids, which hold no spaces
		for uninstall_id in $uninstall_bundle_ids; do
			case " $uninstall_ids_seen " in
			*" $uninstall_id "*) continue ;;
			esac
			uninstall_ids_seen="$uninstall_ids_seen $uninstall_id"
			app_caches "$uninstall_id" >"$TEMP_DIR/caches"
			while IFS= read -r uninstall_cache; do
				remove_path "$uninstall_cache"
			done <"$TEMP_DIR/caches"
		done
	fi

	PURGED=0
	PURGE_SKIPPED=0
	if [ "$PURGE" -eq 1 ]; then
		purge_before="$REMOVE_SKIPPED"
		purge_data
		[ "$REMOVE_SKIPPED" = "$purge_before" ] || PURGE_SKIPPED=1
	fi

	say ""
	if [ "$DRY_RUN" -eq 1 ]; then
		say "dry run: the commands above are what --uninstall would run; nothing was removed."
		return 0
	fi
	if [ -n "$REMOVE_SKIPPED" ]; then
		say "done, except for what could not be removed (see the warnings above):$REMOVE_SKIPPED"
	else
		say "done. $CURRENT_PRODUCT is uninstalled."
	fi
	if [ "$PURGED" -eq 1 ] && [ "$PURGE_SKIPPED" -eq 1 ]; then
		say "Some of what --purge was asked to delete is still there (see the warnings above)."
	elif [ "$PURGED" -eq 1 ]; then
		say "The node's identity and database are deleted too; installing again makes a new node,"
		say "so machines paired with this one need to pair again."
	elif [ "$PURGE" -eq 1 ]; then
		say "Kept: the node's identity and database, which belong to a node that is not this install's (see above)."
	else
		say "Kept: the node's identity and database in $(kept_data_directories), and its logs."
		say "Installing again brings the same node back with its pairings. To delete them as well:"
		say "  curl -fsSL $RAW_SELF | sh -s -- --uninstall --purge"
	fi
	say "Machines paired with this one still list it; remove it there with \`ah revoke <node-id>\` or from their app."
}

# --- main ----------------------------------------------------------------------

main() {
	parse_arguments "$@"
	if [ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ]; then
		die "--purge only goes with --uninstall"
	fi
	if [ "$UNINSTALL" -eq 1 ] && { [ -n "$FROM" ] || [ -n "$VERSION" ] || [ "$CLI_ONLY" -eq 1 ]; }; then
		die "--uninstall removes whatever is installed; --from, --version and --cli-only do not go with it"
	fi

	# Everything below builds a path out of HOME. Unset, it would reach `rm -rf`
	# as an empty string and the shell would say "HOME: unbound variable" from
	# whichever line got there first.
	[ -n "${HOME:-}" ] || die "HOME is not set, so there is nowhere to install to; run this as a normal logged-in user, or pass --prefix DIR"

	OS="$(uname -s)"
	MACHINE="$(uname -m)"
	case "$OS" in
	Darwin) OS_SLUG="darwin" ;;
	Linux) OS_SLUG="linux" ;;
	*) die "$OS is not supported; macOS and Linux only (Windows has an installer on the releases page)" ;;
	esac
	case "$MACHINE" in
	arm64 | aarch64) ARCH_SLUG="arm64" ;;
	x86_64 | amd64) ARCH_SLUG="amd64" ;;
	*) die "unsupported processor $MACHINE; the releases page lists what is built" ;;
	esac

	# The desktop app ships for darwin as one universal .dmg and for linux as an
	# amd64 tarball only. A linux arm64 machine gets the command line archive,
	# and is told so rather than left wondering where the window is.
	if [ "$UNINSTALL" -eq 0 ] && [ "$OS_SLUG" = "linux" ] && [ "$ARCH_SLUG" = "arm64" ] && [ "$CLI_ONLY" -eq 0 ]; then
		say "no desktop build exists for linux arm64; installing the command line tools only"
		CLI_ONLY=1
	fi

	# Which of the two Linux desktop builds this machine can run. Probed here,
	# before any asset name is built, because it decides the download and not
	# just what is printed afterwards. DESKTOP_SUFFIX is what distinguishes the
	# two file names on the release page.
	WEBKIT_ABI=""
	WEBKIT_PROBED=0
	DESKTOP_SUFFIX=""
	if [ "$UNINSTALL" -eq 0 ] && [ "$OS_SLUG" = "linux" ] && [ "$CLI_ONLY" -eq 0 ]; then
		detect_webkit_abi
		case "$WEBKIT_ABI" in
		4.0) DESKTOP_SUFFIX="_webkit40" ;;
		# Everything else takes the 4.1 build: it is what every distribution
		# still adding WebKit2GTK ships, so where nothing is installed it is
		# also the ABI whose runtime the owner can obtain afterwards.
		*) DESKTOP_SUFFIX="" ;;
		esac
		# Every branch says which build it took and why, not only the 4.0 one.
		# The reason is the half that is worth reading: someone whose window
		# does not open needs to know whether the choice was made from what is
		# installed or made blind.
		#
		# Only when it is choosing a download. With --from the file was named on
		# the command line, nothing here selected it, and claiming otherwise
		# would tell someone who took the wrong archive by hand that the right
		# one had been picked for them.
		if [ -z "$FROM" ]; then
			case "$WEBKIT_ABI" in
			4.0) say "this machine has WebKit2GTK 4.0; taking the build linked against it" ;;
			4.1) say "this machine has WebKit2GTK 4.1; taking the build linked against it" ;;
			both) say "this machine has both WebKit2GTK ABIs; taking the 4.1 build" ;;
			*)
				if [ "$WEBKIT_PROBED" -eq 1 ]; then
					say "this machine has no WebKit2GTK runtime installed; taking the 4.1 build"
				else
					# Silence here was the original defect in another form: on a
					# Debian machine whose PATH has no ldconfig the 4.1 archive
					# was taken with nothing printed at all, which is the exact
					# failure this probe exists to prevent.
					say "could not read this machine's WebKit2GTK ABI (no readable ldconfig); taking the 4.1 build"
				fi
				;;
			esac
		fi
	fi

	# --- which release, and so which names ---------------------------------------

	# An uninstall removes both names' installs and needs no release. An
	# install needs the release before any path is built: a tag up to v0.1.11
	# installs under the names it was released with, any later one under the
	# current names (legacy_era_of_tag), and --from says which by its file name.
	if [ "$UNINSTALL" -eq 1 ]; then
		set_names current
	else
		CURL="$(command -v curl 2>/dev/null || true)"
		WGET="$(command -v wget 2>/dev/null || true)"
		if command -v shasum >/dev/null 2>&1; then
			SHA_CMD="shasum"
			SHA_ARGS="-a 256"
		elif command -v sha256sum >/dev/null 2>&1; then
			SHA_CMD="sha256sum"
			SHA_ARGS=""
		else
			die "neither shasum nor sha256sum is on PATH; without one the download cannot be verified"
		fi
		if [ -n "$FROM" ]; then
			if legacy_era_of_archive "$(basename "$FROM")"; then
				set_names legacy
			else
				set_names current
			fi
		else
			resolve_version
			if legacy_era_of_tag "$VERSION"; then
				set_names legacy
			else
				set_names current
			fi
		fi
	fi

	# --- where things go -------------------------------------------------------

	# TREE is where this run's tarball is unpacked, LEGACY_TREE where a
	# pre-rename one was, CURRENT_TREE where a current one is. AGENTHUB_HOME,
	# the pre-rename knob, names all three when the new one is not set: the
	# tree it names is then upgraded in place, and never retired.
	if [ -n "$PREFIX" ]; then
		check_install_directory "--prefix" "$PREFIX"
		APP_PARENT="$PREFIX"
		OTHER_APP_PARENT=""
		BIN_DIR="$PREFIX/bin"
		TREE="${AGENTHALLWAY_HOME:-${AGENTHUB_HOME:-$PREFIX/share/$TREE_NAME}}"
		CURRENT_TREE="${AGENTHALLWAY_HOME:-${AGENTHUB_HOME:-$PREFIX/share/$CURRENT_SLUG}}"
		LEGACY_TREE="${AGENTHUB_HOME:-$PREFIX/share/$LEGACY_SLUG}"
	else
		BIN_DIR="$HOME/.local/bin"
		TREE="${AGENTHALLWAY_HOME:-${AGENTHUB_HOME:-$HOME/.local/share/$TREE_NAME}}"
		CURRENT_TREE="${AGENTHALLWAY_HOME:-${AGENTHUB_HOME:-$HOME/.local/share/$CURRENT_SLUG}}"
		LEGACY_TREE="${AGENTHUB_HOME:-$HOME/.local/share/$LEGACY_SLUG}"
		# /Applications when this account can write it, ~/Applications
		# otherwise. Never sudo: an installer that asks for the administrator
		# password to put a per-user background service in place is asking for
		# more than it needs.
		# AGENTHALLWAY_APPLICATIONS exists for the tests, like
		# AGENTHALLWAY_LDCONFIG_PATHS: a run that fakes uname still sees this
		# machine's real /Applications, and a test of what --uninstall leaves
		# alone needs an app there that is not the developer's own. The
		# pre-rename AGENTHUB_APPLICATIONS is read too, so a test that sets only
		# that one cannot fall through to the real /Applications.
		applications="${AGENTHALLWAY_APPLICATIONS:-${AGENTHUB_APPLICATIONS:-/Applications}}"
		if [ -w "$applications" ]; then
			APP_PARENT="$applications"
			OTHER_APP_PARENT="$HOME/Applications"
		else
			APP_PARENT="$HOME/Applications"
			OTHER_APP_PARENT="$applications"
		fi
		# Install picks /Applications when it is writable and ~/Applications
		# when it is not, and that can change between an install and now (an
		# account made admin). An upgrade's retirement and an uninstall look at
		# both, so an app is found where it is rather than where it would go
		# today.
		if [ "$(absolute_path "$OTHER_APP_PARENT")" = "$(absolute_path "$APP_PARENT")" ]; then
			OTHER_APP_PARENT=""
		fi
	fi
	APP_PATH="$APP_PARENT/$APP_NAME.app"
	OTHER_APP_PATH="${OTHER_APP_PARENT:+$OTHER_APP_PARENT/$APP_NAME.app}"
	CURRENT_APP_PATH="$APP_PARENT/$CURRENT_APP_NAME.app"
	CURRENT_OTHER_APP_PATH="${OTHER_APP_PARENT:+$OTHER_APP_PARENT/$CURRENT_APP_NAME.app}"
	LEGACY_APP_PATH="$APP_PARENT/$LEGACY_APP_NAME.app"
	LEGACY_OTHER_APP_PATH="${OTHER_APP_PARENT:+$OTHER_APP_PARENT/$LEGACY_APP_NAME.app}"
	# A .app bundle is a macOS install and nothing else. On Linux the paths
	# above still name /Applications (they are computed for both), and every
	# step that looks there — an uninstall, an upgrade retiring the pre-rename
	# app — would reach a directory it has no business in: on a mac whose
	# uname says Linux, which is how the tests run, that is the developer's own
	# app. Emptied here, they match nothing: no ah is taken from them, no link
	# counts as pointing into them, no process is matched by them and nothing
	# under them is removed.
	if [ "$OS_SLUG" != "darwin" ]; then
		APP_PATH=""
		OTHER_APP_PATH=""
		CURRENT_APP_PATH=""
		CURRENT_OTHER_APP_PATH=""
		LEGACY_APP_PATH=""
		LEGACY_OTHER_APP_PATH=""
	fi
	INSTALLED_APP=0
	INSTALLED_TREE=0

	if [ "$UNINSTALL" -eq 1 ]; then
		uninstall
		return 0
	fi

	# --- get the archive -------------------------------------------------------

	TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$SLUG-install.XXXXXX")"
	trap cleanup EXIT INT TERM HUP

	if [ -n "$FROM" ]; then
		[ -f "$FROM" ] || die "--from $FROM is not a file"
		ARCHIVE="$FROM"
		ARCHIVE_NAME="$(basename "$FROM")"
		case "$ARCHIVE_NAME" in
		*.dmg) ARCHIVE_KIND="dmg" ;;
		*.tar.gz) ARCHIVE_KIND="tgz" ;;
		*) die "--from wants a .dmg or a .tar.gz, got $ARCHIVE_NAME" ;;
		esac
		SUMS="$(dirname "$FROM")/SHA256SUMS"
		if [ -f "$SUMS" ]; then
			verify "$ARCHIVE" "$SUMS" "$ARCHIVE_NAME"
		else
			warn "no SHA256SUMS beside $ARCHIVE_NAME; installing it unverified because you named the file yourself"
		fi
		say "installing from $ARCHIVE_NAME"
	else
		if [ "$CLI_ONLY" -eq 1 ]; then
			ARCHIVE_NAME="${CLI_ASSET}${VERSION}_${OS_SLUG}_${ARCH_SLUG}.tar.gz"
			ARCHIVE_KIND="tgz"
		elif [ "$OS_SLUG" = "darwin" ]; then
			ARCHIVE_NAME="${DESKTOP_ASSET}${VERSION}_darwin_universal.dmg"
			ARCHIVE_KIND="dmg"
		else
			ARCHIVE_NAME="${DESKTOP_ASSET}${VERSION}_linux_amd64${DESKTOP_SUFFIX}.tar.gz"
			ARCHIVE_KIND="tgz"
		fi
		ARCHIVE="$TEMP_DIR/$ARCHIVE_NAME"
		SUMS="$TEMP_DIR/SHA256SUMS"
		say "downloading $ARCHIVE_NAME"
		download_failed="release $VERSION has no $ARCHIVE_NAME.
Releases before the desktop builds carry the command line archives only — re-run with --cli-only, or pick a newer tag at https://github.com/${REPO}/releases"
		if ! fetch "$DOWNLOAD_BASE/$VERSION/$ARCHIVE_NAME" "$ARCHIVE"; then
			# The _webkit40 asset only exists from the release that introduced the
			# second Linux build. Asked for an older tag, a 4.0 machine would
			# otherwise be told its only option was --cli-only, when the plain
			# archive is right there — it is the 4.1 build, so it may not start,
			# and that is said rather than left to be discovered.
			[ -n "$DESKTOP_SUFFIX" ] || die "$download_failed"
			warn "release $VERSION has no $ARCHIVE_NAME; that tag predates the WebKit 4.0 build.
Falling back to ${DESKTOP_ASSET}${VERSION}_linux_amd64.tar.gz, which is linked against WebKit2GTK 4.1 and may not start on this machine. For a build that matches it, pick a newer tag at https://github.com/${REPO}/releases"
			DESKTOP_SUFFIX=""
			ARCHIVE_NAME="${DESKTOP_ASSET}${VERSION}_linux_amd64.tar.gz"
			ARCHIVE="$TEMP_DIR/$ARCHIVE_NAME"
			say "downloading $ARCHIVE_NAME"
			fetch "$DOWNLOAD_BASE/$VERSION/$ARCHIVE_NAME" "$ARCHIVE" ||
				die "release $VERSION has no $ARCHIVE_NAME.
Releases before the desktop builds carry the command line archives only — re-run with --cli-only, or pick a newer tag at https://github.com/${REPO}/releases"
		fi
		fetch "$DOWNLOAD_BASE/$VERSION/SHA256SUMS" "$SUMS" ||
			die "release $VERSION has no SHA256SUMS, so the download cannot be verified; nothing was installed"
		verify "$ARCHIVE" "$SUMS" "$ARCHIVE_NAME"
	fi

	# A pre-rename release refuses a machine that has moved on, before
	# anything is replaced.
	legacy_era_guard

	# Unpacked or mounted, and checked to be the release its name says, before
	# anything installed is stopped or replaced.
	if [ "$ARCHIVE_KIND" = "dmg" ]; then
		if [ "$OS_SLUG" != "darwin" ]; then
			die "a .dmg is a macOS disk image; on Linux pass the linux tar.gz"
		fi
		mount_dmg
	else
		prepare_tarball
	fi

	# --- install ---------------------------------------------------------------

	run mkdir -p "$BIN_DIR"
	if [ -n "$PREFIX" ]; then
		# So that the next run can tell this directory is one of ours before it
		# replaces anything in it.
		run mkdir -p "$PREFIX"
		run touch "$PREFIX/$MARKER"
	fi

	case "$OS_SLUG" in
	darwin)
		if [ "$ERA" = current ]; then
			quit_legacy_apps
		fi
		if [ "$ARCHIVE_KIND" = "dmg" ]; then
			install_macos_app
			INSTALLED_APP=1
		else
			install_tarball_tree
			INSTALLED_TREE=1
		fi
		;;
	linux)
		if [ "$NO_SERVICE" -eq 0 ]; then
			stop_linux_node
		fi
		install_tarball_tree
		INSTALLED_TREE=1
		if [ "$CLI_ONLY" -eq 0 ]; then
			install_desktop_entry
			webkit_hint
		fi
		;;
	esac

	ensure_path
	install_claude_skill

	# `ah service install` writes the unit that starts the node at login, and it
	# writes the absolute path of the node beside this ah. Running it on every
	# upgrade — rather than only the first time — is what keeps an owner who
	# moved from ~/Applications to /Applications from being left with a unit
	# that points at a path this script just deleted. From v0.2.0 it also
	# retires the pre-rename registration, carrying its database over.
	if [ "$NO_SERVICE" -eq 1 ]; then
		say "skipped the background service (--no-service)"
		SERVICE_STATE="not registered (--no-service); \"$AH\" service install registers it"
	else
		register_service
	fi

	if [ "$ERA" = current ]; then
		retire_legacy_install
		warn_stale_mcp_configs
	fi

	if [ "$OS_SLUG" = "darwin" ] && [ "$CLI_ONLY" -eq 0 ] && [ "$ARCHIVE_KIND" = "dmg" ] && [ "$NO_OPEN" -eq 0 ]; then
		run open "$APP_PATH"
	fi

	closing_lines
}

main "$@"
