# DO NOT EDIT MANUALLY.
# This file provides shared tasks common to all projects and managed by limen.
# If you want to add project specific tasks, you can do so in the `project.just` file.

set working-directory := '..'

# Silence just's per-line command echo; recipes announce themselves via _banner.
set quiet

# Shared private _banner recipe (see _lib.just).
import '_lib.just'

default: just yaml

just: (_banner "fix" "just")
    #!/usr/bin/env bash
    set -euo pipefail
    # --cached --others --exclude-standard: tracked *and* new untracked files,
    # still honoring .gitignore — so a not-yet-staged file is formatted too.
    git ls-files -z --cached --others --exclude-standard 'justfile' 'Justfile' '*.just' '**/justfile' \
      | xargs -0 -I{} just --fmt --justfile {}

rust: (_banner "fix" "rust")
    cargo clippy --fix --all-targets --all-features --allow-dirty --allow-staged
    cargo fmt --all

go: (_banner "fix" "go")
    golangci-lint fmt
    golangci-lint run --fix

yaml: (_banner "fix" "yaml")
    yamlfmt -conf .just/.yamlfmt .
