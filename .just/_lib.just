# DO NOT EDIT MANUALLY.
# This file provides shared tasks common to all projects and managed by limen.
# If you want to add project specific tasks, you can do so in the `project.just` file.

# Uniform per-recipe banner, shared across the lint/fix/tools modules via `import`
# (a `mod` can't be depended on, and modules don't inherit the parent's recipes).
# Private → hidden from --list. The module name is passed in because just has no
# current-module variable; depended on with arguments so it prints identically for
# plain *and* shebang recipes, which just otherwise echoes inconsistently (plain
# recipes echo their lines; shebang recipes do not).
_banner mod name:
    @echo "▶ {{ mod }}: {{ name }}"
