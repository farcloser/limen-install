# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

lint: do::lint::default do::lint::go::default do::lint::go::deadcode
fix: do::fix::default do::fix::go::default
test: do::test::go::default installer-checksum smoke

# --- added by limen fix: the recipe the security workflow runs ---
security: do::security::default

# The installer script pins aqua-installer by version and sha256, and the
# script refuses itself when the two disagree. The checksum workflow keeps
# them paired on Renovate's branches, but nothing in CI ever ran the download,
# so a version bump that left the old sha256 behind was green until a laptop
# ran it. This downloads the pinned installer and compares.
installer-checksum:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(sed -n 's/^readonly AQUA_INSTALLER_VERSION="\(.*\)"$/\1/p' limen-install)
    expected=$(sed -n 's/^readonly AQUA_INSTALLER_SHA256="\(.*\)"$/\1/p' limen-install)
    [ -n "$version" ] && [ -n "$expected" ] || { echo "limen-install: AQUA_INSTALLER_VERSION or AQUA_INSTALLER_SHA256 not found" >&2; exit 1; }
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/installer-checksum.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$scratch/aqua-installer" \
        "https://raw.githubusercontent.com/aquaproj/aqua-installer/${version}/aqua-installer"
    actual=$(sha256sum "$scratch/aqua-installer" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        echo "aqua-installer ${version} hashes to ${actual}, limen-install pins ${expected}: the pair moved apart" >&2
        exit 1
    fi
    echo "aqua-installer ${version}: sha256 matches the pin"

# The installer end to end, in a throwaway HOME with the system's tools and
# nothing of this machine's: aqua and limen installed, the config written, the
# rc appended, and on macOS the nightly agent's runner and plist written and
# valid. Run from that HOME, as a user would, so no project manifest is in
# reach. On a developer machine LIMEN_INSTALL_NO_LAUNCHD keeps both services
# out of the machine's launchd domain, where the nightly job would collide
# with the real one's label and the ssh-agent step would replace the real
# agent with a throwaway package; on a GitHub runner, thrown away after the
# job, the knob is off and both services are loaded, checked and booted out:
# the real path, tested. TMPDIR and the proxy variables pass through: the
# machine's, not the test's.
[unix]
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    home=$(mktemp -d "${TMPDIR:-/tmp}/limen-install-smoke.XXXXXX")
    trap 'rm -rf "$home"' EXIT
    script="$PWD/limen-install"
    (cd "$home" && env -i HOME="$home" USER="${USER:-}" SHELL=/bin/bash PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
        GITHUB_TOKEN="${GITHUB_TOKEN:-}" AQUA_GITHUB_TOKEN="${AQUA_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}" \
        HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" NO_PROXY="${NO_PROXY:-}" \
        http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" no_proxy="${no_proxy:-}" \
        LIMEN_INSTALL_NO_LAUNCHD="$([ -n "${GITHUB_ACTIONS:-}" ] && echo 0 || echo 1)" bash "$script")
    test -s "$home/.config/aqua/aqua.yaml"
    grep -q AQUA_GLOBAL_CONFIG "$home/.bashrc"
    (cd "$home" && AQUA_GLOBAL_CONFIG="$home/.config/aqua/aqua.yaml" AQUA_POLICY_CONFIG="$home/.config/aqua/aqua-policy.yaml" \
        HOME="$home" PATH="$home/.local/share/aquaproj-aqua/bin:/usr/bin:/bin:/usr/sbin:/sbin" limen version)
    if [ "$(uname -s)" = Darwin ]; then
        # The macOS toolset resolved by name: aqua ignores a pin it cannot place
        # (a registry it does not find, a file the tarball lacks) with an error
        # line and still ends the install, so the run alone proves nothing.
        for tool in ssh-agent-install sshd-install taciturn; do
            (cd "$home" && AQUA_GLOBAL_CONFIG="$home/.config/aqua/aqua.yaml" AQUA_POLICY_CONFIG="$home/.config/aqua/aqua-policy.yaml" \
                HOME="$home" PATH="$home/.local/share/aquaproj-aqua/bin:/usr/bin:/bin:/usr/sbin:/sbin" aqua which "$tool" > /dev/null)
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
