# limen-hermetic: the toolset's own aqua

The design delta for the machine toolset's resolver, decided 2026-10-14, before any
code. What is here describes the end state; the sections at the end say what moves,
in what order, and what the human does by hand.

## The problem

Every tool a machine runs through the toolset, `limen`, the ssh fork, `taciturn`,
resolves through this chain when typed in a shell:

1. PATH finds `<aqua root>/bin/<tool>`, a symlink aqua created to `../aqua-proxy`.
2. `<aqua root>/aqua-proxy` is a symlink to the upstream aqua-proxy binary aqua
   downloaded into its package store.
3. aqua-proxy reads its own `argv[0]` and execs the literal word `aqua` with
   `exec -- <tool> <args>`. The word is resolved through the caller's PATH, and the
   child inherits the caller's environment.
4. Whatever `aqua` that is decides the root from `AQUA_ROOT_DIR` or aqua's default,
   reads the config chain (the directory's `aqua.yaml` upward, then
   `AQUA_GLOBAL_CONFIG`), finds the pin, installs it if missing, and execs the real
   binary from the package store.

Steps 3 and 4 are decided by the shell's PATH and environment at the moment the
command is typed. That is why the installer wrote the toolset into aqua's default
root and into a global config of its own at `${XDG_CONFIG_HOME:-~/.config}/aqua/aqua.yaml`
(or the file a preset `AQUA_GLOBAL_CONFIG` named, rewritten whole on every run), and
exported `AQUA_GLOBAL_CONFIG` and `AQUA_POLICY_CONFIG` into the human's rc: nothing
else makes the shims land in the toolset. aqua has no default global config; the
variable is what names one. The cost is that the human's own aqua, for anything that
is not the toolset, shares the root and reads the toolset's config and policy on
every run.

Three facts, verified in the sources at the pinned versions, bound the fix:

- aqua-proxy's command is a constant, `aqua`, resolved through PATH; nothing in it
  reads a path, a variable or its own location.
- aqua's installer relinks `<root>/bin/<tool>` to `../aqua-proxy` and
  `<root>/aqua-proxy` to upstream's download whenever the targets differ, on every
  install. A replacement proxy under aqua's own paths is overwritten on the next
  run: a second writer, not a design.
- aqua's root, config file names, `AQUA_*` variables and the proxy's name are
  library constants. The program name the CLI is built with reaches its help text
  and nothing else.

## The binary

One binary, `limen-hermetic`, built from aqua as a Go library: `cli.Run` behind our
own `main`. It is aqua, pinned by `go.mod` and moved by Renovate like every Go
dependency, with three things of ours around it.

**It dispatches on `argv[0]`.** Invoked under its own name it is aqua, every
subcommand included. Invoked under any other name, through a link, it runs
`exec -- <that name> <args>` in process. No second binary and no upstream proxy:
the links point at `limen-hermetic` itself, at one path. A symlink survives the
binary's replacement; a hard link does not, which Windows below handles.

**It derives aqua's three paths from one root of ours.** `LIMEN_HERMETIC_ROOT_DIR`,
or its default when unset, is the root; the binary sets `AQUA_ROOT_DIR`,
`AQUA_GLOBAL_CONFIG` and `AQUA_POLICY_CONFIG` from it before the library reads the
environment, and the shell's values of those three are not consulted. Every other
`AQUA_*` variable passes through (`AQUA_GITHUB_TOKEN`, `AQUA_LOG_LEVEL`, …). aqua
reads a fourth input for the same three, its settings file at
`${XDG_CONFIG_HOME:-~/.config}/aquaproj-aqua/config.yaml`, whose `root_dir`,
`global_config` and `policy.config` apply when the matching variable is empty; the
binary always sets the three, so that file never reaches the toolset and stays the
human's.

**It keeps its own `bin`.** After the subcommands that install (`install`,
`update`, `generate`, and the lazy install inside `exec`) it mirrors the command
names aqua exposed in `<root>/aqua/bin`, `aqua` itself excepted, into `<root>/bin`
as links to itself, adding and removing so the two sets match, and comparing
targets rather than names: a link whose target is not the binary, a hard link's
file identity included, is recreated. aqua's `bin` is never on anyone's PATH; ours
is. aqua may relink its own directory as it likes, since nothing reads it but this
mirror. (`aqua` is excepted because `update-aqua` places upstream's binary there;
a mirrored `aqua` would dispatch to it.)

## The root

```
$LIMEN_HERMETIC_ROOT_DIR/            default: ${XDG_DATA_HOME:-~/.local/share}/limen-hermetic
                                              %LOCALAPPDATA%\limen-hermetic on Windows
├── bin/
│   ├── limen-hermetic               the binary; the one PATH entry a shell needs
│   ├── limen -> limen-hermetic      the mirrored links (hard links on Windows)
│   ├── ssh -> limen-hermetic
│   └── …
├── aqua.yaml                        the global config: the toolset's pins (AQUA_GLOBAL_CONFIG)
├── registry.yaml                    the farcloser registry
├── aqua-policy.yaml                 the policy (AQUA_POLICY_CONFIG)
└── aqua/                            aqua's own root (AQUA_ROOT_DIR): pkgs, bin, policies, …
```

The machine toolset lives in the default root. A Claude Code session has its own,
`~/.local/share/limen-agent/hermetic`, named by `LIMEN_HERMETIC_ROOT_DIR` in the
sessions' settings env where `AQUA_ROOT_DIR` is named today; the sandbox write list
follows. Baked defaults apply only when the variable is unset, so the sessions' root
stays theirs with the same binary.

A shell's own aqua, if it has one, is untouched: its root, its global config and
its policy are what aqua's defaults say, and nothing of ours is exported into the
shell beyond the PATH entry.

## The project directory

A project's pins live in `.hermetic/`, not `.aqua/`: `hermetic.yaml` (the pins, with
the `import: ../.limen/aqua.yaml` line as today, since an import is a path),
`policy.yaml`, and `aqua-checksums.json`, the one file that keeps aqua's name
because the library writes it beside the config under a fixed name.

aqua's own finder walks upward for `aqua.yaml`, `.aqua/aqua.yaml` and their
variants, library constants, but `AQUA_CONFIG` names one config file outright. So
`limen-hermetic` does the walk itself, upward from the working directory for
`.hermetic/hermetic.yaml`, and sets `AQUA_CONFIG` to what it finds before the
library runs. `-c` and an explicit `AQUA_CONFIG` win over the walk, for the recipe
that runs on a scratch copy of the manifest.

The project's policy keeps its gate. Everything `AQUA_POLICY_CONFIG` names is
trusted on sight by the library; only a policy its own finder locates beside a
config is validated against the record `policy allow` wrote under
`<root>/aqua/policies/`, and dropped with a warning when the record is missing or
stale, so a cloned repository cannot allow a registry of its choosing and have the
lazy install run that registry's binary under a tool's name. Our walk replaces the
finder, so the binary does the validation itself with the library's exported
validator: `.hermetic/policy.yaml` joins `AQUA_POLICY_CONFIG` only when its record
under `<root>/aqua/policies/` matches, and is otherwise dropped with the same
warning. `limen-hermetic policy allow .hermetic/policy.yaml` stays the one-time
gate per machine, in the setup action and the book under the new path. The one
policy trusted on sight is the toolset's own, in the root, as today.

Two consequences:

- Renovate's aqua preset detects pins by the names `.aqua/aqua.yaml` and
  `aqua.yaml`; with ours it detects nothing. The canonical `.limen/renovate.json`
  carries its own copy of the preset's regex managers, pointed at `.hermetic/`, and
  stops extending upstream's; upstream's later changes to those managers no longer
  follow us, and they are a few regexes.
- A stock aqua finds no pins in our repositories, which is the point and the cost:
  only `limen-hermetic` resolves them.

`fix` renames a repository's `.aqua/` to `.hermetic/` once on its limen bump, the
way it moves `tools/` to `.limen/tools/` today; the `aqua` rule, `tools.just`, the
setup action's `policy allow`, the checksum workflow and the book move with it.

## The hermetic PATH in the recipes

limen's canonical `main.just` builds the recipes' PATH today from aqua's root:
`$AQUA_ROOT_DIR/bin` or aqua's default, then the base system. It builds it from
`$LIMEN_HERMETIC_ROOT_DIR/bin` or our default instead, and the recipes that call
`aqua` by name (`tools.just`, `lib.just`'s download prefix) call `limen-hermetic`.
The project files are `.hermetic/`'s (above); the canonical `.limen/aqua.yaml` they
import keeps its name.

One recipe case needs a switch of ours. `tools.just` runs aqua on a project's own
pins alone, today by `env -u AQUA_GLOBAL_CONFIG`, which the binary's derivation would
undo. `LIMEN_HERMETIC_GLOBAL_CONFIG=none` tells the binary to set
`AQUA_GLOBAL_CONFIG` to a value that names no file, a lone list separator, which
aqua's parser skips as empty entries; not to leave it empty, since an empty variable
lets the human's settings file's `global_config` fall through. The recipe sets it
where it unset the variable.

## CI

The canonical setup action installs `limen-hermetic` on the runner instead of
upstream aqua: the release asset from limen-install at a pinned version, its
checksum pinned in the action and moved by Renovate as `AQUA_VERSION` is today, and
`gh attestation verify` against limen-install's release workflow where `gh` exists
(every GitHub runner). Then `limen-hermetic i` as before. The action's name follows
the tool; the content-pinned rule carries the rename to the fleet with a limen
release.

## Bootstrap and release

limen-install becomes a Go repository beside its scripts: `go.mod`,
`cmd/limen-hermetic`, goreleaser through limen's canonical release lane, binaries
for darwin/arm64, linux/amd64, linux/arm64, windows/amd64 and windows/arm64,
`checksums.txt`, attestations on every asset. The scripts and the binary share one
tag.

`limen-install` fetches the binary from its own release at that tag, under a
checksum pinned in the script, where aqua-installer and its checksum are pinned
today, and places it at `<root>/bin/limen-hermetic`; the toolset's config, registry
and policy go beside it, and `limen-hermetic i -a` installs the toolset. There is no
`aqua update-aqua` any more: the binary is ours, and only our release replaces it.
The nightly job runs the installer as it does today and takes the new binary with
it. `limen-install.ps1` does the same with the Windows asset, with one difference. The
links there are hard links, a second name for the file as it was linked, so
replacing the binary detaches every one of them; and a running dispatch holds the
file open, since the library runs the tool as a child and waits. The installer
replaces the binary by renaming the old one aside and writing the new, then
recreates every hard link, which is what aqua does for its own proxy; the mirror's
identity comparison catches any it missed.

Renovate: the aqua library through `go.mod` (our own cooldown rule applies to
nothing here; upstream's three days do); the `limen-hermetic` pin in the installer
script and in the setup action through the regex managers that watch the aqua pins
today.

## Migration

For the human, once the installer carries this:

- Remove the three lines the old installer appended to the rc: the `# aqua` PATH
  entry, `export AQUA_GLOBAL_CONFIG=…`, `export AQUA_POLICY_CONFIG=…`. The new
  installer appends its one PATH line.
- Delete `~/.config/aqua/aqua.yaml` and its `registry.yaml` and `aqua-policy.yaml`
  beside it if their header says limen-install wrote them. A preset
  `AQUA_GLOBAL_CONFIG` of the human's names their own file again, and the settings
  file at `~/.config/aquaproj-aqua/config.yaml`, if they keep one, is theirs
  untouched.
- Leave `~/.local/share/aquaproj-aqua`: it is the human's root now, and the toolset's
  packages in it are dead weight until pruned, harmless.
- Run `limen-install-agent` once more: the sessions' settings env names
  `LIMEN_HERMETIC_ROOT_DIR` instead of `AQUA_ROOT_DIR`, and their root moves.

## Order of work

1. This delta.
2. limen-install: the module, the binary, the release lane. The scripts still
   install upstream aqua; CI still uses upstream's setup action.
3. limen-install: the scripts bootstrap `limen-hermetic`, write the root, write the
   one rc line; `limen-install-agent` names the sessions' root.
4. limen: `main.just`, `tools.just`, `lib.just`, the setup action, the `aqua` rule
   with the `.aqua/` to `.hermetic/` migration, the Renovate managers, the book, as
   one canonical change, shipped by a release; the fleet follows on its bump.
5. The human's migration, by the list above.
