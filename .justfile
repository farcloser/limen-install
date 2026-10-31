# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

lint: do::lint::default
fix: do::fix::default
test: installer-checksum smoke farclauder

# --- added by limen fix: the recipe the security workflow runs ---
security: do::security::default

# The installer script pins hermetic by version and by the sha256 of its
# release's checksums.txt, and the script refuses itself when the two
# disagree. The checksum workflow keeps them paired on Renovate's branches,
# but nothing in CI would otherwise run the download, so a version bump that
# left the old sha256 behind would be green until a laptop ran it. This
# downloads the pinned release's checksums.txt and compares.
installer-checksum:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(sed -n 's/^readonly HERMETIC_VERSION="\(.*\)"$/\1/p' limen-install)
    expected=$(sed -n 's/^readonly HERMETIC_CHECKSUMS_SHA256="\(.*\)"$/\1/p' limen-install)
    [ -n "$version" ] && [ -n "$expected" ] || { echo "limen-install: HERMETIC_VERSION or HERMETIC_CHECKSUMS_SHA256 not found" >&2; exit 1; }
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/installer-checksum.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$scratch/checksums.txt" \
        "https://github.com/forkcloser/hermetic/releases/download/${version}/checksums.txt"
    actual=$(sha256sum "$scratch/checksums.txt" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        echo "hermetic ${version}'s checksums.txt hashes to ${actual}, limen-install pins ${expected}: the pair moved apart" >&2
        exit 1
    fi
    echo "hermetic ${version}: checksums.txt matches the pin"

# The installer end to end, in a throwaway HOME with the system's tools and
# nothing of this machine's: hermetic and limen installed into the default
# root under that HOME, the pins written, the rc appended, and on macOS the
# nightly agent's runner and plist written and valid. Run from that HOME, as
# a user would, so no project manifest is in reach. On a developer machine
# LIMEN_INSTALL_NO_LAUNCHD keeps both services out of the machine's launchd
# domain, where the nightly job would collide with the real one's label and
# the ssh-agent step would replace the real agent with a throwaway package;
# on a GitHub runner, thrown away after the job, the knob is off and both
# services are loaded, checked and booted out: the real path, tested. TMPDIR
# and the proxy variables pass through: the machine's, not the test's. The
# token reaches hermetic as HERMETIC_GITHUB_TOKEN, the one it reads.
[unix]
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    home=$(mktemp -d "${TMPDIR:-/tmp}/limen-install-smoke.XXXXXX")
    trap 'rm -rf "$home"' EXIT
    script="$PWD/limen-install"
    (cd "$home" && env -i HOME="$home" USER="${USER:-}" SHELL=/bin/bash PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
        GITHUB_TOKEN="${GITHUB_TOKEN:-}" HERMETIC_GITHUB_TOKEN="${HERMETIC_GITHUB_TOKEN:-${AQUA_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}}" \
        HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" NO_PROXY="${NO_PROXY:-}" \
        http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" no_proxy="${no_proxy:-}" \
        LIMEN_INSTALL_NO_LAUNCHD="$([ -n "${GITHUB_ACTIONS:-}" ] && echo 0 || echo 1)" bash "$script")
    if [ "$(uname -s)" = Darwin ]; then
        root="$home/Library/Application Support/hermetic"
    else
        root="$home/.local/share/hermetic"
    fi
    test -s "$root/hermetic.yaml"
    test -s "$root/aqua-checksums.json"
    test -x "$root/bin/hermetic"
    grep -qF '/hermetic}/bin' "$home/.bashrc"
    # The one PATH entry, and limen and gh through their links, from a
    # directory with no project: the root is the binary's default under this
    # HOME, and a root pin answers where no project's does.
    (cd "$home" && env -i HOME="$home" PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" limen version)
    (cd "$home" && env -i HOME="$home" PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" gh --version > /dev/null)
    if [ "$(uname -s)" = Darwin ]; then
        # The macOS toolset resolved by name: a pin that cannot be placed (a
        # registry not found, a file the tarball lacks) is an error line and
        # the install still ends, so the run alone proves nothing.
        for tool in ssh-agent-install sshd-install taciturn; do
            (cd "$home" && env -i HOME="$home" PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" hermetic which "$tool" > /dev/null)
        done
        test -x "$home/.local/share/limen-install/nightly"
        plutil -lint "$home/Library/LaunchAgents/world.farcloser.limen-install.plist"
        sh -n "$home/.local/share/limen-install/nightly"
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            domain="gui/$(id -u)"
            for label in world.farcloser.limen-install org.forkcloser.ssh_agent; do
                launchctl print "$domain/$label" > /dev/null
                launchctl bootout "$domain/$label"
            done
            for label in org.forkcloser.sshd org.forkcloser.taciturn; do
                if launchctl print "$domain/$label" > /dev/null 2>&1; then
                    echo "limen-install: $label was not loaded and the run loaded it" >&2
                    exit 1
                fi
            done
            echo "limen-install: both services loaded on the runner and booted out; the server and taciturn left alone"
        fi
    fi
    echo "limen-install: end to end in a throwaway HOME, ok"

[windows]
smoke:
    @echo "limen-install: the end-to-end run is unix-only (limen-install.ps1 drives git-bash on Windows)"

# farclauder, as limen-install-agent writes it, run against throwaway clones:
# it removes a worktree whose checkout git has already deleted, with its
# record, and refuses everything else: a live checkout, a record that names
# another path, a symlink on the way, a relative path, a name with a slash.
[unix]
farclauder:
    #!/usr/bin/env bash
    set -euo pipefail
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/farclauder.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    scratch=$(cd -P "$scratch" && pwd -P)
    tool="$scratch/farclauder"
    sed -n "/^  cat > \"\$FARCLAUDER\" <<'SH'$/,/^SH$/p" limen-install-agent | sed '1d;$d' > "$tool"
    chmod 755 "$tool"
    [ -s "$tool" ] || { echo "farclauder: not found in limen-install-agent" >&2; exit 1; }
    clone() { # clone <repo> <name> [live]: a clone with one registered worktree
        mkdir -p "$1/.git/worktrees/$2" "$1/.claude/worktrees/$2/.claude"
        printf '%s\n' "$1/.claude/worktrees/$2/.git" > "$1/.git/worktrees/$2/gitdir"
        printf '../..\n' > "$1/.git/worktrees/$2/commondir"
        : > "$1/.claude/worktrees/$2/.claude/settings.json"
        if [ "${3:-}" = live ]; then printf 'gitdir: %s\n' "$1/.git/worktrees/$2" > "$1/.claude/worktrees/$2/.git"; fi
    }
    refuses() { # refuses <why> <args...>
        local why=$1; shift
        if "$tool" "$@" 2>/dev/null; then echo "farclauder did not refuse: $why" >&2; exit 1; fi
        echo "refuses: $why"
    }
    r="$scratch/repo"
    clone "$r" dead
    "$tool" worktree remove "$r/.claude/worktrees/dead" > /dev/null
    [ ! -e "$r/.claude/worktrees/dead" ] && [ ! -e "$r/.git/worktrees/dead" ] || { echo "dead worktree not removed" >&2; exit 1; }
    echo "removes: a worktree whose checkout is gone, and its record"
    clone "$r" gone && rm -rf "$r/.claude/worktrees/gone"
    "$tool" worktree remove "$r/.claude/worktrees/gone" > /dev/null
    [ ! -e "$r/.git/worktrees/gone" ] || { echo "record of a removed worktree left" >&2; exit 1; }
    echo "removes: the record of a worktree already gone"
    clone "$r" live live
    refuses "a live checkout" worktree remove "$r/.claude/worktrees/live"
    [ -e "$r/.claude/worktrees/live/.git" ] && [ -e "$r/.git/worktrees/live" ] || { echo "live worktree touched" >&2; exit 1; }
    clone "$r" other && printf '%s\n' "$scratch/elsewhere/.git" > "$r/.git/worktrees/other/gitdir"
    refuses "a record that names another path" worktree remove "$r/.claude/worktrees/other"
    mkdir -p "$scratch/real/.claude/worktrees" && clone "$scratch/real" sym && ln -s "$scratch/real" "$scratch/link"
    refuses "a symlink on the way" worktree remove "$scratch/link/.claude/worktrees/sym"
    refuses "a relative path" worktree remove repo/.claude/worktrees/dead
    refuses "a name outside .claude/worktrees" worktree remove "$r/.git/worktrees/live"
    refuses "no record" worktree remove "$r/.claude/worktrees/none"
    refuses "another command" worktree delete "$r/.claude/worktrees/dead"

[windows]
farclauder:
    @echo "farclauder: macOS only, as limen-install-agent, which installs it"
