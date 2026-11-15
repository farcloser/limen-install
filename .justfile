# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

lint: do::lint::default
fix: do::fix::default
test: installer-checksum smoke pin-write agent-put farclauder merge-settings agent-root

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
    if [ "$(uname -s)" = Darwin ]; then
        root="$home/Library/Application Support/hermetic"
    else
        root="$home/.local/share/hermetic"
    fi
    # The stage a killed run left: the install must end well over it, and
    # leave none (below).
    mkdir -p "$root/.pins" && echo stale > "$root/.pins/stale"
    (cd "$home" && env -i HOME="$home" USER="${USER:-}" SHELL=/bin/bash PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
        GITHUB_TOKEN="${GITHUB_TOKEN:-}" HERMETIC_GITHUB_TOKEN="${HERMETIC_GITHUB_TOKEN:-${AQUA_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}}" \
        HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" NO_PROXY="${NO_PROXY:-}" \
        http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" no_proxy="${no_proxy:-}" \
        LIMEN_INSTALL_NO_LAUNCHD="$([ -n "${GITHUB_ACTIONS:-}" ] && echo 0 || echo 1)" bash "$script")
    test -s "$root/hermetic.yaml"
    # The pins are staged, then renamed into place: nothing of either is left.
    if [ -e "$root/.pins" ] || find "$root" -maxdepth 1 \( -name '.*.yaml.*' -o -name '.*.json.*' \) | grep -q .; then
        echo "limen-install: a staged pin file was left in $root" >&2
        exit 1
    fi
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
        # The runner's own judgement of a release, lifted from the runner the
        # install wrote: later or equal runs, older and anything else does not.
        judge="$home/judge"
        {
            sed -n '/^older() {$/,/^}$/p; /^release() {$/,/^}$/p; /^accept() {$/,/^}$/p' "$home/.local/share/limen-install/nightly"
            # shellcheck disable=SC2016 # the lifted script's own arguments
            printf '%s\n' 'accept "$1" "$2"'
        } > "$judge"
        grep -q '^accept() {$' "$judge" || { echo "limen-install: the nightly runner has no accept function" >&2; exit 1; }
        printf 'v0.9.0\n' > "$home/last"
        for tag in v0.9.0 v0.10.0 v1.0.0; do
            sh "$judge" "$tag" "$home/last" || { echo "limen-install: the nightly runner refused $tag after v0.9.0" >&2; exit 1; }
        done
        sh "$judge" v0.10.0 "$home/absent" || { echo "limen-install: the nightly runner refused a first release" >&2; exit 1; }
        for tag in v0.8.9 v0.2.10 latest v1.2 'v1.2.3;x' ''; do
            if sh "$judge" "$tag" "$home/last" 2> /dev/null; then
                echo "limen-install: the nightly runner accepted \"$tag\" after v0.9.0" >&2
                exit 1
            fi
        done
        # What the runner does with that judgement, on its own lines from the
        # judgement to its end: a refused release ends the run before the
        # installer, and only a run that ended well is recorded. A function
        # shadows a command whatever PATH the runner sets, so curl, perl and
        # bash are stand-ins here: the fetch records its URL, the installer
        # that it ran and ends as told. The runner's `set -eu` is its own
        # line too: it is what ends the run when the installer fails.
        runs="$home/runs"
        {
            sed -n '/^set -eu$/p' "$home/.local/share/limen-install/nightly"
            # shellcheck disable=SC2016 # the lifted script's own variables
            printf '%s\n' 'tag="$1"; last="$2"; seen="$3"; ends="$4"' \
                'curl() { for arg in "$@"; do url="$arg"; done; printf "%s\n" "$url" > "$seen.url"; }' \
                'perl() { : > "$seen.ran"; return "$ends"; }' \
                'bash() { : > "$seen.ran"; return "$ends"; }'
            sed -n '/^older() {$/,/^}$/p; /^release() {$/,/^}$/p; /^accept() {$/,/^}$/p' "$home/.local/share/limen-install/nightly"
            sed -n '/^accept "\$tag" "\$last" || exit 1$/,$p' "$home/.local/share/limen-install/nightly"
        } > "$runs"
        # shellcheck disable=SC2016 # the runner's own lines, looked for as they are written
        for line in 'set -eu' 'accept "$tag" "$last" || exit 1' 'mv -f "$last.new" "$last"'; do
            grep -qF -- "$line" "$runs" || { echo "limen-install: \`$line\` not found in the nightly runner" >&2; exit 1; }
        done
        # ran <tag> <the installer's exit>: the runner's exit, whether the
        # installer ran, and the record afterwards, from a record of v0.9.0.
        ran() {
            printf 'v0.9.0\n' > "$home/last"
            rm -f "$home/seen.ran" "$home/seen.url"
            code=0
            sh "$runs" "$1" "$home/last" "$home/seen" "$2" > /dev/null 2>&1 || code=$?
            printf '%s %s %s\n' "$code" "$([ -e "$home/seen.ran" ] && echo ran || echo 'not run')" "$(cat "$home/last")"
        }
        [ "$(ran v0.8.9 0)" = '1 not run v0.9.0' ] || { echo "limen-install: an older release, in the runner: $(ran v0.8.9 0)" >&2; exit 1; }
        [ "$(ran v0.10.0 0)" = '0 ran v0.10.0' ] || { echo "limen-install: a later release, in the runner: $(ran v0.10.0 0)" >&2; exit 1; }
        [ "$(cat "$home/seen.url")" = 'https://raw.githubusercontent.com/farcloser/limen-install/refs/tags/v0.10.0/limen-install' ] || { echo "limen-install: the runner fetched $(cat "$home/seen.url")" >&2; exit 1; }
        [ "$(ran v0.10.0 1)" = '1 ran v0.9.0' ] || { echo "limen-install: a later release whose installer failed, in the runner: $(ran v0.10.0 1)" >&2; exit 1; }
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

# limen-install's write of the pins into the root, which the sessions' tool
# root reads through links at any hour: `put` and `install_tools`, lifted as
# merge-settings lifts its function, run on a throwaway root with a stand-in
# for hermetic that checks what the root holds each time it is called. The
# root must never hold pins without their checksums, every file must arrive
# by a rename (a hard link to the old file keeps the old bytes), and a run
# whose checksums fail must leave the root as it was.
[unix]
pin-write:
    #!/usr/bin/env bash
    set -euo pipefail
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/pin-write.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    scratch=$(cd -P "$scratch" && pwd -P)
    root="$scratch/the root"
    harness="$scratch/harness"
    standin="$scratch/hermetic"
    files="hermetic.yaml registry.yaml policy.yaml aqua-checksums.json"
    # The stand-in: `--log-level warn -c <config> <command> [flag]`. Each call
    # checks the root as a reader would find it at that moment, then does
    # what the command does to the checksums beside the config it is given.
    # shellcheck disable=SC2016 # the stand-in's own variables, expanded when it runs
    printf '%s\n' '#!/bin/sh' 'set -eu' \
        'config="$4"; call="$5${6:+ $6}"; dir="${config%/*}"' \
        'holds() { [ "$(cat "$ROOT/$1")" = "$2" ] || { echo "pin-write: at \`$call\` the root'"'"'s $1 is \`$(cat "$ROOT/$1")\`, want \`$2\`" >&2; exit 1; }; }' \
        'staged() { [ "$dir" = "$ROOT/.pins" ] || { echo "pin-write: \`$call\` on $config, not on the stage" >&2; exit 1; }; }' \
        'echo "$call" >> "$CALLS"' \
        'case "$call" in' \
        '  update-checksum)' \
        '    staged; holds hermetic.yaml "old pins"; holds aqua-checksums.json "old checksums"' \
        '    [ ! -e "$dir/policy.yaml" ] || { echo "pin-write: a policy.yaml beside the staged config" >&2; exit 1; }' \
        '    [ "$(cat "$dir/aqua-checksums.json")" = "old checksums" ] || { echo "pin-write: the stage does not start from the root'"'"'s checksums" >&2; exit 1; }' \
        '    [ "${FAIL:-}" != checksums ] || exit 1' \
        '    echo "old and new checksums" > "$dir/aqua-checksums.json" ;;' \
        '  "update-checksum --prune")' \
        '    staged; holds hermetic.yaml "new pins"; holds registry.yaml "new registry"; holds policy.yaml "new policy"' \
        '    holds aqua-checksums.json "old and new checksums"' \
        '    echo "new checksums" > "$dir/aqua-checksums.json" ;;' \
        '  "install -a")' \
        '    [ "$config" = "$ROOT/hermetic.yaml" ] || { echo "pin-write: install on $config" >&2; exit 1; }' \
        '    holds hermetic.yaml "new pins"; holds aqua-checksums.json "new checksums"' \
        '    [ ! -e "$ROOT/.pins" ] || { echo "pin-write: the stage outlives the write" >&2; exit 1; } ;;' \
        '  *) echo "pin-write: unexpected call \`$call\`" >&2; exit 1 ;;' \
        'esac' > "$standin"
    chmod 755 "$standin"
    {
        # shellcheck disable=SC2016 # the harness's own $ROOT, expanded when it runs
        printf 'set -euo pipefail\nok() { :; }\nROOT=%q\nSTAGE="$ROOT/.pins"\nhermetic_bin() { echo %q; }\n' "$root" "$standin"
        # Every rename, watched: what a reader finds between two of them.
        # shellcheck disable=SC2016 # the harness's own variables
        printf '%s\n' 'mv() {' '  command mv "$@"' \
            '  if [ "$(cat "$ROOT/hermetic.yaml")" = "new pins" ] && [ "$(cat "$ROOT/aqua-checksums.json")" = "old checksums" ]; then' \
            '    echo "pin-write: the root holds the new pins with the old checksums" >&2; exit 1' \
            '  fi' '}'
        sed -n '/^put() {/,/^}$/p' limen-install
        sed -n '/^install_tools() {$/,/^}$/p' limen-install
        printf 'install_tools\n'
    } > "$harness"
    for line in 'put() {' 'install_tools() {'; do
        grep -qF -- "$line" "$harness" || { echo "pin-write: \`$line\` not found in limen-install" >&2; exit 1; }
    done
    # A root with yesterday's files, a hard link to each, and today's stage.
    fresh() {
        rm -rf "$root" "$scratch/witness" "$scratch/calls"
        mkdir -p "$root/.pins" "$scratch/witness"
        printf 'old pins\n' > "$root/hermetic.yaml"
        printf 'old registry\n' > "$root/registry.yaml"
        printf 'old policy\n' > "$root/policy.yaml"
        printf 'old checksums\n' > "$root/aqua-checksums.json"
        for f in $files; do ln "$root/$f" "$scratch/witness/$f"; done
        printf 'new pins\n' > "$root/.pins/hermetic.yaml"
        printf 'new registry\n' > "$root/.pins/registry.yaml"
        printf 'new policy\n' > "$root/.pins/root-policy.yaml"
    }
    fresh
    ROOT="$root" CALLS="$scratch/calls" bash "$harness"
    [ "$(tr '\n' ',' < "$scratch/calls")" = 'update-checksum,update-checksum --prune,install -a,' ] || { echo "pin-write: hermetic was called as: $(tr '\n' ',' < "$scratch/calls")" >&2; exit 1; }
    echo "ordered: the checksums of old and new pins, then the pins, then the prune"
    for f in $files; do
        old="old ${f%.*}"; old="${old/hermetic/pins}"; old="${old/aqua-checksums/checksums}"
        [ "$(cat "$scratch/witness/$f")" = "$old" ] || { echo "pin-write: $f was written over, not renamed in: its old link reads \`$(cat "$scratch/witness/$f")\`" >&2; exit 1; }
        [ ! "$root/$f" -ef "$scratch/witness/$f" ] || { echo "pin-write: $f was not replaced" >&2; exit 1; }
    done
    [ "$(find "$root" -mindepth 1 | wc -l | tr -d ' ')" = 4 ] || { echo "pin-write: the root holds more than its four files:" >&2; find "$root" -mindepth 1 >&2; exit 1; }
    echo "renames: each of the four files, nothing staged left behind"
    fresh
    if ROOT="$root" CALLS="$scratch/calls" FAIL=checksums bash "$harness" 2> "$scratch/err"; then
        echo "pin-write: a run whose checksums failed ended well" >&2
        exit 1
    fi
    for f in $files; do
        [ "$root/$f" -ef "$scratch/witness/$f" ] || { echo "pin-write: $f changed in a run whose checksums failed" >&2; exit 1; }
    done
    echo "keeps: the root as it was when the checksums fail"

[windows]
pin-write:
    @echo "pin-write: unix only, as the bash harness it runs limen-install's functions in"

# `put`, as limen-install-agent writes every file a session reads or runs:
# the function lifted from the script. A hard link to the old file keeps the
# old bytes when the new one is renamed in, and reads the new ones when the
# file is written over.
[unix]
agent-put:
    #!/usr/bin/env bash
    set -euo pipefail
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/agent-put.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    harness="$scratch/harness"
    target="$scratch/a directory/the file"
    mkdir -p "${target%/*}"
    {
        printf 'set -euo pipefail\n'
        sed -n '/^put() {/,/^}$/p' limen-install-agent
        # shellcheck disable=SC2016 # the harness's own arguments
        printf '%s\n' 'put "$1" "$2"'
    } > "$harness"
    grep -q '^put() {' "$harness" || { echo "agent-put: \`put() {\` not found in limen-install-agent" >&2; exit 1; }
    printf 'old\n' > "$target"
    chmod 0644 "$target"
    ln "$target" "$scratch/witness"
    printf 'new\n' | bash "$harness" 0755 "$target"
    [ "$(cat "$target")" = new ] || { echo "agent-put: the file reads \`$(cat "$target")\`" >&2; exit 1; }
    [ "$(cat "$scratch/witness")" = old ] || { echo "agent-put: the file was written over, not renamed in" >&2; exit 1; }
    [ -n "$(find "$target" -maxdepth 0 -perm 755)" ] || { echo "agent-put: the file is not 0755, the mode asked for" >&2; exit 1; }
    [ "$(find "${target%/*}" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || { echo "agent-put: something staged was left:" >&2; find "${target%/*}" -mindepth 1 >&2; exit 1; }
    echo "renames: new content into place with its mode, nothing staged left"
    printf 'first\n' | bash "$harness" 0600 "${target%/*}/another"
    if [ "$(cat "${target%/*}/another")" != first ] || [ -z "$(find "${target%/*}/another" -maxdepth 0 -perm 600)" ]; then
        echo "agent-put: a file that was not there is not written, or not 0600" >&2
        exit 1
    fi
    echo "creates: a file that was not there"

[windows]
agent-put:
    @echo "agent-put: unix only, as the bash harness it runs limen-install-agent's function in"

# farclauder, as limen-install-agent writes it, run against throwaway clones:
# it removes a worktree, checkout and record, and refuses everything else: a
# locked worktree, a record that names another path, a symlink on the way, a
# relative path, a name outside .claude/worktrees.
[unix]
farclauder:
    #!/usr/bin/env bash
    set -euo pipefail
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/farclauder.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    scratch=$(cd -P "$scratch" && pwd -P)
    tool="$scratch/farclauder"
    sed -n "/^  put 0755 \"\$FARCLAUDER\" <<'SH'$/,/^SH$/p" limen-install-agent | sed '1d;$d' > "$tool"
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
    clone "$r" live live && mkdir "$r/.claude/worktrees/live/.claude/.cc-writes" && : > "$r/.claude/worktrees/live/file"
    "$tool" worktree remove "$r/.claude/worktrees/live" > /dev/null
    [ ! -e "$r/.claude/worktrees/live" ] && [ ! -e "$r/.git/worktrees/live" ] || { echo "checkout not removed" >&2; exit 1; }
    echo "removes: a checkout, its .claude entries, and its record, in one call"
    clone "$r" locked live && : > "$r/.git/worktrees/locked/locked"
    refuses "a locked worktree" worktree remove "$r/.claude/worktrees/locked"
    [ -e "$r/.claude/worktrees/locked/.git" ] && [ -e "$r/.git/worktrees/locked" ] || { echo "locked worktree touched" >&2; exit 1; }
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

# merge_settings, as limen-install-agent runs it, against a throwaway HOME:
# the script's own PATH line and function, lifted from the file into a
# harness where every name the script makes readonly is readonly too, so what
# the real run would refuse is refused here first (a readonly name used as an
# environment prefix was met on a human's machine). The names are read from
# the script's `readonly` lines; the block that derives the paths from
# CLAUDE_HOME is lifted whole, since the function uses them, and the rest
# stand in. Any other line outside the comments that says `readonly`, or
# `declare` or `typeset` with an r among its options, fails the recipe: its
# names would not be read. A declaration split across lines is not seen.
# From an empty settings file it must write what every session depends on;
# from a human's file it must keep what is theirs and drop what the installer
# retired; and a second run must rewrite nothing.
[unix]
merge-settings:
    #!/usr/bin/env bash
    set -euo pipefail
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/merge-settings.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    scratch=$(cd -P "$scratch" && pwd -P)
    home="$scratch/home"
    settings="$home/.claude/settings.json"
    harness="$scratch/harness"
    names=$(sed -n 's/^readonly //p' limen-install-agent | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g" | tr ' ' '\n' | sed -e 's/=.*//' -e '/^$/d' | sort -u)
    for name in $names; do
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "merge-settings: \`$name\`, read from a readonly line of limen-install-agent, is not a name" >&2; exit 1; }
    done
    made=$(grep -E '(^|[^A-Za-z0-9_])readonly([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(declare|typeset)[[:space:]].*-[A-Za-z]*r[A-Za-z]*([[:space:]]|$)' limen-install-agent | grep -cvE '^[[:space:]]*#' || true)
    plain=$(grep -c '^readonly ' limen-install-agent || true)
    [ "$made" = "$plain" ] || { echo "merge-settings: outside its comments limen-install-agent has $made lines that say \`readonly\`, or \`declare\` or \`typeset\` with an r among the options, and $plain are \`readonly\` lines in column 0, the one form this recipe reads the names from" >&2; exit 1; }
    {
        printf 'set -euo pipefail\n'
        sed -n '/^PATH="\/usr\/bin:/p' limen-install-agent
        printf 'ok() { :; }\nunset CLAUDE_CONFIG_DIR\nHOME=%q\n' "$home"
        # shellcheck disable=SC2016 # the harness expands these, not this recipe
        printf '%s\n' 'AGENT_SOCKET="$HOME/agent.sock"' 'AGENT_ROOT="$HOME/.local/share/limen-agent"' 'WRITE=("$HOME/Projects/one" "$HOME/Projects/two words")'
        awk '/^readonly CLAUDE_HOME=/{block=1} block && !/^readonly /{exit} block' limen-install-agent
        for name in $names; do
            # shellcheck disable=SC2016 # the harness expands it, not this recipe
            printf ': "${%s=stand-in}"\nreadonly %s\n' "$name" "$name"
        done
        sed -n '/^merge_settings() {$/,/^}$/p' limen-install-agent
        printf 'merge_settings\n'
    } > "$harness"
    for line in 'PATH="/usr/bin:' 'readonly CLAUDE_HOME=' 'readonly SETTINGS=' 'readonly AGENT_ROOT' 'readonly WRITE' 'merge_settings() {'; do
        grep -qF -- "$line" "$harness" || { echo "merge-settings: \`$line\` not found in limen-install-agent" >&2; exit 1; }
    done
    check() { # check <fresh|kept>: what the merged file must hold
        python3 -I - "$settings" "$home" "$1" <<'PY'
    import json, sys
    path, home, mode = sys.argv[1:4]
    with open(path) as f:
        merged = json.load(f)
    root, claude, socket = home + "/.local/share/limen-agent", home + "/.claude", home + "/agent.sock"
    env, perms, box = merged["env"], merged["permissions"], merged["sandbox"]
    writes, net = box["filesystem"]["allowWrite"], box["network"]
    facts = {
        "env.GIT_CONFIG_GLOBAL is the bot's gitconfig": env["GIT_CONFIG_GLOBAL"] == claude + "/gitconfig",
        "env.SSH_AUTH_SOCK is the agent socket": env["SSH_AUTH_SOCK"] == socket,
        "env.HERMETIC_ROOT_DIR is under the agent root": env["HERMETIC_ROOT_DIR"] == root + "/hermetic",
        "permissions.allow carries the force push": "Bash(git push --force-with-lease=*)" in perms["allow"],
        "permissions.deny carries the baseline": {"Read(~/.s*)", "Edit(./.claude/settings.json)"} <= set(perms["deny"]),
        "sandbox.filesystem.allowWrite starts with the --write directories, then the agent root":
            writes[:3] == ["~/Projects/one", "~/Projects/two words", "~/.local/share/limen-agent"],
        "sandbox.network.allowUnixSockets carries the agent socket": socket in net["allowUnixSockets"],
        "sandbox.network carries the domain lists": "github.com" in net["allowedDomains"] and "uploads.github.com" in net["deniedDomains"],
        "sandbox.excludedCommands carries farclauder by its absolute path": claude + "/bin/farclauder worktree remove *" in box["excludedCommands"],
    }
    if mode == "kept":
        hooks = json.dumps(merged["hooks"])
        facts.update({
            "a human's own keys survive": env.get("MINE") == "1" and merged.get("model") == "mine",
            "a human's own permission rules survive": "Bash(ls *)" in perms["allow"] and "Read(~/mine)" in perms["deny"],
            "a human's own sandbox entries survive": "example.org" in net["allowedDomains"] and "~/elsewhere" in writes,
            "a human's own hook survives": "keep-me" in hooks,
            "the retired git identity block is gone": not [k for k in env if k.startswith("GIT_CONFIG_") and k != "GIT_CONFIG_GLOBAL"],
            "the retired `git c` allow rule is gone": "Bash(git c push --force-with-lease=*)" not in perms["allow"],
            "the retired write locations are gone": "~/go" not in writes and not [w for w in writes if w.startswith("/var/folders/")],
            "the retired hook is gone": "allow-sandboxed-bash" not in hooks,
        })
    failed = [what for what, holds in facts.items() if not holds]
    if failed:
        sys.exit("merge-settings (" + mode + "): not true: " + "; ".join(failed))
    PY
    }
    twice() { # twice <fresh|kept>: merge, check, merge again, and the file must not move
        bash "$harness"
        check "$1"
        cp "$settings" "$scratch/first"
        bash "$harness"
        cmp -s "$settings" "$scratch/first" || { echo "merge-settings ($1): a second run rewrote the file" >&2; diff "$scratch/first" "$settings" >&2 || true; exit 1; }
    }
    twice fresh
    echo "merges: an absent settings file into the sessions' baseline, and a second run rewrites nothing"
    rm -rf "$home" && mkdir -p "$home/.claude"
    cat > "$settings" <<'JSON'
    {
      "model": "mine",
      "env": {"MINE": "1", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "someone"},
      "permissions": {"allow": ["Bash(ls *)", "Bash(git c push --force-with-lease=*)"], "deny": ["Read(~/mine)"]},
      "sandbox": {
        "filesystem": {"allowWrite": ["~/elsewhere", "~/go", "/var/folders/xx/T"]},
        "network": {"allowedDomains": ["example.org"]}
      },
      "hooks": {"PreToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/hooks/allow-sandboxed-bash"}]},
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-me"}]}
      ]}
    }
    JSON
    cp "$settings" "$scratch/before"
    twice kept
    echo "merges: a human's settings file, keeping what is theirs and dropping what the installer retired"
    # A file only its owner reads, with no backup yet, and a hard link to it:
    # the link keeps the old bytes when the merged file is renamed in, and
    # reads the new ones when it is written over.
    rm -rf "$home" && mkdir -p "$home/.claude" && cp "$scratch/before" "$settings"
    chmod 0600 "$settings"
    ln "$settings" "$scratch/witness"
    bash "$harness"
    cmp -s "$settings.bak" "$scratch/before" || { echo "merge-settings: the backup is not the file as it was" >&2; exit 1; }
    echo "keeps: the file as it was, beside the merged one"
    cmp -s "$scratch/witness" "$scratch/before" || { echo "merge-settings: the settings file was written over, not renamed in" >&2; exit 1; }
    for f in "$settings" "$settings.bak"; do
        [ -n "$(find "$f" -maxdepth 0 -perm 600)" ] || { echo "merge-settings: $f is not 0600 after the merge of a file that was" >&2; exit 1; }
    done
    echo "renames: the merged file into place, it and a first backup with the old file's mode"
    # A settings file that does not parse: nothing is written, and the backup
    # of the last file that did is still there.
    cp "$settings.bak" "$scratch/good-backup"
    printf '{ "env": ' > "$settings"
    cp "$settings" "$scratch/broken"
    if bash "$harness" 2> "$scratch/err"; then
        echo "merge-settings: a settings file that is not JSON was merged" >&2
        exit 1
    fi
    cmp -s "$settings.bak" "$scratch/good-backup" || { echo "merge-settings: a broken settings file replaced the backup" >&2; exit 1; }
    cmp -s "$settings" "$scratch/broken" || { echo "merge-settings: a broken settings file was rewritten" >&2; exit 1; }
    grep -qF 'is not JSON' "$scratch/err" || { echo "merge-settings: the refusal does not say why:" >&2; cat "$scratch/err" >&2; exit 1; }
    [ ! -e "$settings.new" ] || { echo "merge-settings: a staged settings file was left behind" >&2; exit 1; }
    echo "refuses: a settings file that does not parse, the backup untouched"

[windows]
merge-settings:
    @echo "merge-settings: unix only, as the bash harness it runs limen-install-agent's function in"

# install_agent_root, as limen-install-agent runs it, against a throwaway
# machine root and sessions' root: the function and the script's own
# declarations, lifted as merge-settings lifts its own, with a stand-in for
# the machine's hermetic. The sessions' pins must be the machine's files
# themselves, so that what limen-install writes at night is what a session
# reads the next morning: a copy froze them at the day this script last ran.
[unix]
agent-root:
    #!/usr/bin/env bash
    set -euo pipefail
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/agent-root.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    scratch=$(cd -P "$scratch" && pwd -P)
    machine="$scratch/machine root"
    agent="$scratch/home/.local/share/limen-agent"
    harness="$scratch/harness"
    mkdir -p "$machine/bin" "$scratch/home"
    for f in hermetic.yaml registry.yaml policy.yaml aqua-checksums.json; do
        printf 'first %s\n' "$f" > "$machine/$f"
    done
    # The machine's hermetic, as far as the function asks it: where its root
    # is, and its version.
    # shellcheck disable=SC2016 # the stand-in's own $1, expanded when it runs
    printf '%s\n' '#!/bin/sh' 'case "$1" in' "  root-dir) echo \"$machine/store\" ;;" '  version) echo 0.0.0 ;;' 'esac' > "$machine/bin/hermetic"
    chmod 755 "$machine/bin/hermetic"
    {
        printf 'set -euo pipefail\n'
        sed -n '/^PATH="\/usr\/bin:/p' limen-install-agent
        printf 'ok() { :; }\nerr() { printf "%%s\\n" "$*" >&2; }\nunset CLAUDE_CONFIG_DIR\nHOME=%q\nAGENT_ROOT=%q\nMACHINE_HERMETIC=%q\n' \
            "$scratch/home" "$agent" "$machine/bin/hermetic"
        awk '/^readonly CLAUDE_HOME=/{block=1} block && !/^readonly /{exit} block' limen-install-agent
        sed -n '/^install_agent_root() {$/,/^}$/p' limen-install-agent
        printf 'install_agent_root\n'
    } > "$harness"
    for line in 'PATH="/usr/bin:' 'readonly AGENT_HERMETIC=' 'install_agent_root() {'; do
        grep -qF -- "$line" "$harness" || { echo "agent-root: \`$line\` not found in limen-install-agent" >&2; exit 1; }
    done
    linked() { # linked: every pin file and the binary are the machine's own
        for f in hermetic.yaml registry.yaml policy.yaml aqua-checksums.json bin/hermetic; do
            if [ ! -L "$agent/hermetic/$f" ] || [ ! "$agent/hermetic/$f" -ef "$machine/$f" ]; then
                echo "agent-root: $agent/hermetic/$f is not a link to the machine's $f" >&2
                ls -l "$agent/hermetic" "$agent/hermetic/bin" >&2
                exit 1
            fi
        done
    }
    bash "$harness"
    linked
    echo "links: the sessions' pins and binary to the machine's"
    # The nightly's write: a new file renamed over the old one.
    printf 'second\n' > "$machine/.staged" && mv -f "$machine/.staged" "$machine/hermetic.yaml"
    [ "$(cat "$agent/hermetic/hermetic.yaml")" = second ] || { echo "agent-root: the sessions' root did not follow the machine's new pins" >&2; exit 1; }
    echo "follows: a pin file the machine's installer replaced"
    # A root an earlier version of the script filled with copies.
    for f in hermetic.yaml registry.yaml policy.yaml aqua-checksums.json; do
        rm "$agent/hermetic/$f" && printf 'a stale copy\n' > "$agent/hermetic/$f"
    done
    bash "$harness"
    linked
    echo "replaces: the copies an earlier run left"
    rm "$machine/registry.yaml"
    if bash "$harness" 2> "$scratch/err"; then
        echo "agent-root: a machine root without its registry was accepted" >&2
        exit 1
    fi
    grep -qF 'registry.yaml is missing' "$scratch/err" || { echo "agent-root: the refusal does not name the missing file:" >&2; cat "$scratch/err" >&2; exit 1; }
    echo "refuses: a machine root that lacks a pin file"
    # A session's own shell: the machine's hermetic answers the sessions' root.
    # Four real files there, as a root filled by copies has.
    printf 'second\n' > "$machine/registry.yaml"
    for f in hermetic.yaml registry.yaml policy.yaml aqua-checksums.json; do
        rm "$agent/hermetic/$f" && printf 'the sessions own %s\n' "$f" > "$agent/hermetic/$f"
    done
    # shellcheck disable=SC2016 # the stand-in's own $1, expanded when it runs
    printf '%s\n' '#!/bin/sh' 'case "$1" in' "  root-dir) echo \"$agent/hermetic/store\" ;;" '  version) echo 0.0.0 ;;' 'esac' > "$machine/bin/hermetic"
    if HERMETIC_ROOT_DIR="$agent/hermetic" bash "$harness" 2> "$scratch/err"; then
        echo "agent-root: a hermetic that answers the sessions' root was accepted" >&2
        exit 1
    fi
    grep -qF "HERMETIC_ROOT_DIR=$agent/hermetic" "$scratch/err" || { echo "agent-root: the refusal does not name the shell's root:" >&2; cat "$scratch/err" >&2; exit 1; }
    for f in hermetic.yaml registry.yaml policy.yaml aqua-checksums.json; do
        if [ -L "$agent/hermetic/$f" ] || [ "$(cat "$agent/hermetic/$f")" != "the sessions own $f" ]; then
            echo "agent-root: $agent/hermetic/$f did not survive a run from a session's shell" >&2
            exit 1
        fi
    done
    echo "refuses: a shell whose hermetic root is the sessions' own, the files untouched"

[windows]
agent-root:
    @echo "agent-root: unix only, as the bash harness it runs limen-install-agent's function in"
