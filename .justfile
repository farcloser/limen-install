# This file is the project's own — add recipes below. Keep the import: it
# mounts every shared limen task under `just do ...`.
import '.limen/just/main.just'

lint: do::lint::default
fix: do::fix::default
test: installer-checksum

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
