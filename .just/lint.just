# DO NOT EDIT MANUALLY.
# This file provides shared tasks common to all projects and managed by limen.
# If you want to add project specific tasks, you can do so in the `project.just` file.

set working-directory := '..'

# Silence just's per-line command echo; recipes announce themselves via _banner.
set quiet

# Shared private _banner recipe (see _lib.just).
import '_lib.just'

default: just aqua links yaml shell

just: (_banner "lint" "just")
    #!/usr/bin/env bash
    set -euo pipefail
    # --cached --others --exclude-standard: tracked *and* new untracked files,
    # still honoring .gitignore — so a not-yet-staged file is linted too.
    git ls-files -z --cached --others --exclude-standard 'justfile' 'Justfile' '*.just' '**/justfile' \
      | xargs -0 -I{} just --fmt --check --justfile {}

rust: (_banner "lint" "rust")
    cargo fmt --all --check
    cargo clippy --all-targets --all-features -- --deny warnings

go: (_banner "lint" "go")
    golangci-lint run
    golangci-lint fmt --diff

yaml: (_banner "lint" "yaml")
    yamlfmt -conf .just/.yamlfmt -lint .

shell: (_banner "lint" "shell")
    #!/usr/bin/env bash
    set -euo pipefail
    # A file is a shell script if it declares itself one, by either signal:
    #   - a .sh/.bash extension → a missing shebang is then a lint error (SC2148), or
    #   - a shebang on line 1 for a dialect shellcheck lints (sh/bash/dash/ksh —
    #     not zsh, which shellcheck cannot check) → covers extension-less scripts.
    # Filtering on the shebang alone would silently skip an *.sh that forgot its shebang.
    # No mapfile (bash 4+): build the array with a read loop, portable to bash 3.2.
    files=()
    while IFS= read -r -d '' f; do
        case "$f" in
            *.sh|*.bash) files+=("$f"); continue ;;
        esac
        head -n 1 "$f" 2>/dev/null | grep -qE '^#!.*\b(bash|dash|ksh|sh)\b' && files+=("$f")
    done < <(git ls-files -z --cached --others --exclude-standard)
    [ ${#files[@]} -eq 0 ] || shellcheck --rcfile .just/.shellcheckrc "${files[@]}"

# Check documentation links with lychee (respects .gitignore, skips hidden files).
links: (_banner "lint" "links")
    #!/usr/bin/env bash
    set -euo pipefail
    # A directory input (not a glob) is what makes lychee honor .gitignore/hidden.
    # Canonical exclusions (and their rationale) live in .just/lychee.toml; a
    # repository adds its own in a root lychee.toml. Both must be passed
    # explicitly — any --config disables lychee's ./lychee.toml auto-discovery —
    # and lychee merges them, concatenating the exclude lists.
    args=(--config .just/lychee.toml)
    if [ -f lychee.toml ]; then
        args+=(--config lychee.toml)
    fi
    lychee --no-progress "${args[@]}" .

# Verify aqua-checksums.json is complete and in sync with aqua.yaml.
aqua: (_banner "lint" "aqua")
    #!/usr/bin/env bash
    set -euo pipefail
    # aqua has no read-only validator, so regenerate and compare against the
    # committed file (needs network). `git diff HEAD` is staging-independent — it
    # compares the working tree to the last commit, not the index. On drift the
    # corrected file is left in place — review and commit it.
    # --log-level warn: the per-package INFO lines are noise when nothing is wrong.
    aqua --log-level warn update-checksum --prune
    if ! git diff --quiet HEAD -- aqua-checksums.json; then
        echo "aqua-checksums.json was out of sync with aqua.yaml (regenerated above) — review and commit it." >&2
        exit 1
    fi
