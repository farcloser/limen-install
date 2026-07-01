# limen-install

One script to get a machine ready for development.

It installs our key requirement ([aqua](https://aquaproj.github.io/), a declarative CLI version manager),
and pins exactly one global tool through it: [`limen`](https://github.com/farcloser/limen), our project scaffolding and verification tool.

Everything else is per-project, and once a project is scaffolded, can be done through `just`.

## Usage

```bash
./limen-install
```

The script is idempotent, and can be used for fresh install and updates.

What it does:
- **aqua**: install (checksum-verified) if not already present.
- **shell config**: your `PATH` and `AQUA_GLOBAL_CONFIG` are appended to your shell rc
  only if missing. If anything changed, open a new shell to pick it up.
- **global config**: the aqua global config is written with `limen` as its sole package.
- **tools**: `aqua install --all` installs limen.

## After bootstrapping

Set up a repository with:

```bash
limen bootstrap [--license] [path]
[cd path]
aqua policy allow && aqua install --only-link
```
