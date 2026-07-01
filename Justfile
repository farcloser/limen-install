# DO NOT EDIT MANUALLY.
# This file provides shared tasks common to all projects and managed by limen.
# If you want to add project specific tasks, you can do so in the `project.just` file.

# Project name, derived from the directory the root Justfile lives in.
project := file_name(justfile_directory())

# Hermetic PATH: aqua-pinned tools + base system only (no homebrew), so any tool that
# isn't pinned fails loudly instead of silently resolving to an unpinned copy.
aqua_bin := env_var_or_default('AQUA_ROOT_DIR', env_var_or_default('XDG_DATA_HOME', home_directory() / '.local/share') / 'aquaproj-aqua') / 'bin'
export PATH := aqua_bin + ":/usr/bin:/bin:/usr/sbin:/sbin"

# Show this list of recipes.
default:
    @just --list

# Print meaningful information about this project.
info:
    @echo "name:     {{ project }}"
    @echo "upstream: $(git remote get-url origin 2>/dev/null || echo '(none)')"
    @echo "semver:   $(git describe --tags --abbrev=0 2>/dev/null || echo '(none)')"
    @echo "commit:   $(git rev-parse --short HEAD 2>/dev/null || echo '(none)')"
    @echo "date:     $(git log --max-count=1 --format=%cd --date=short 2>/dev/null || echo '(none)')"

mod tools '.just/tools.just'
mod lint '.just/lint.just'
mod fix '.just/fix.just'
import? 'project.just'
