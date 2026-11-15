# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

lint: do::lint::default
fix: do::fix::default
test: installer-checksum smoke farclauder merge-settings

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
    rm -rf "$home" && mkdir -p "$home/.claude" && cp "$scratch/before" "$settings"
    bash "$harness"
    cmp -s "$settings.bak" "$scratch/before" || { echo "merge-settings: the backup is not the file as it was" >&2; exit 1; }
    echo "keeps: the file as it was, beside the merged one"

[windows]
merge-settings:
    @echo "merge-settings: unix only, as the bash harness it runs limen-install-agent's function in"
