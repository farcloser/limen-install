# limen-install

One script to get a machine ready for development.

It installs [hermetic](https://github.com/forkcloser/hermetic), the toolset's own aqua, in
a root of its own, and through it the machine toolset: [`limen`](https://github.com/farcloser/limen),
our project scaffolding and verification tool, and on macOS/arm64 the OpenSSH fork and
taciturn.

Everything else is per-project, and once a project is scaffolded, can be done through `just`.

## Usage

```bash
./limen-install
```

The script is idempotent, and can be used for fresh install and updates.

What it does:
- **hermetic**: the pinned release's binary, placed at `<root>/bin/hermetic`, verified
  against the release's `checksums.txt` whose sha256 the script pins, and against
  GitHub's build provenance where `gh` is signed in; an already-present binary is
  converged to the pinned version.
- **shell config**: one line, the root's `bin` on your `PATH`, appended to your shell rc
  only if missing. If anything changed, open a new shell to pick it up.
- **the pins**: `hermetic.yaml`, `registry.yaml` and `policy.yaml` in the root, the
  toolset's pins, rewritten on every run.
- **tools**: `hermetic install -a` installs the toolset into the root's store, and the
  root's `bin` gets one link per tool, each a name for `hermetic` itself.

## The root

The root is `HERMETIC_ROOT_DIR`, or hermetic's default for the platform:
`~/Library/Application Support/hermetic` on macOS, `${XDG_DATA_HOME:-~/.local/share}/hermetic`
on Linux, `%LOCALAPPDATA%\hermetic` on Windows. Its `bin` is the one PATH entry a shell
needs; `limen`, `ssh` and the rest are links there to `hermetic`, which resolves the name
from the root's pins and runs the tool. A shell's own aqua, if it has one, is untouched:
its root, its global config and its policy are its own, and nothing of the toolset is
exported into the shell beyond the PATH entry. The design is
[hermetic's docs/design.md](https://github.com/forkcloser/hermetic/blob/main/docs/design.md).

A machine set up by the previous installer keeps three lines in its rc that nothing reads
any more, the `# aqua` PATH entry, `AQUA_GLOBAL_CONFIG` and `AQUA_POLICY_CONFIG`: remove
them, and the `aqua.yaml`, `registry.yaml` and `aqua-policy.yaml` under `~/.config/aqua`
whose header says limen-install wrote them. `~/.local/share/aquaproj-aqua` is your own aqua's
root now; the toolset's packages in it are dead weight until pruned, harmless. Then run
`limen-install-agent` again: the sessions' root moves with it.

## The toolset

The root's pins are the machine toolset: `limen`, and on macOS/arm64
[forkcloser/openssh](https://github.com/forkcloser/openssh) — OpenSSH with security keys
built in (`ssh`, `ssh-agent`, `ssh-add`, `ssh-keygen`, `ssh-keyscan`, `scp`, `sftp`,
`ssh-agent-install`, `sshd-install`, `sshd-uninstall`) and
[forkcloser/taciturn](https://github.com/forkcloser/taciturn), the ssh-agent for Secure
Enclave keys the sessions sign and push through; both are skipped elsewhere. Renovate moves
the pins here, and a tag ships them to every machine the next night. The ssh-agent
launchd agent (`org.forkcloser.ssh_agent`) is part of the toolset: it runs the package by its
real path, so whenever the loaded agent is not the pinned package — none loaded, an older
one, a hand-unpacked one — the script runs the package's `ssh-agent-install`, which installs
and starts it. The server (`org.forkcloser.sshd`) is yours to turn on and off with
`sshd-install` and `sshd-uninstall`: the script only moves a loaded server onto the pinned
package, and never starts or stops one. taciturn's agent (`org.forkcloser.taciturn`) is
yours to install once, `taciturn install`, with the bot's key and its policy; the script only
moves a loaded agent onto the pinned package the same way. `LIMEN_INSTALL_NO_LAUNCHD=1`
makes a run load no service — neither the agent nor the nightly job; their files are still
written — for a test in a throwaway HOME on a machine with a real agent.

## The nightly update job (macOS)

The first run installs a launchd agent, `world.farcloser.limen-install`, that re-runs the
latest release of this script every night (04:17 local; log in
`~/Library/Logs/limen-install.log`). It fetches the script over plain https from the
release tag — no clone, no credential, no key: the trust is TLS to github.com and the
ruleset that lets only the repository's admins create a `v*` tag — and runs it with the
system's tools first on `PATH`, and a preset root exported, since launchd sources no rc.
Renovate moves the pins in this repository; a tag ships them to every machine the next
night. The agent is reloaded when its plist changes, except from inside the nightly run
itself (that would kill the running job; the next login loads it). Linux and Windows get
no job yet: run the script by hand there.

## Versioning

A tag is a version of this repository, on its own line: the script, the nightly
job and the toolset it pins change at their own pace, and a tag says that
something here changed, not which limen it installs. The limen it installs is
the pin in `write_config`, which Renovate moves like the others; `limen
version` on the machine is the answer to that question. Tags are signed and
cut by hand on `main`. There are no release assets: a tag's source tarball is
the release.

[homebrew-brews](https://github.com/farcloser/homebrew-brews)'
`Formula/limen.rb` installs from that tarball and takes its version from the
tag, so `brew upgrade` follows every tag.

## Letting a coding agent contribute: limen-install-agent

A second, optional bootstrap sets a machine up so a Claude Code session can
commit and push as a **dedicated bot identity** — signed commits, over ssh,
from inside its sandbox — without ever holding a key it could read. The
reasoning and the doctrine are the "coding agents as contributors" chapter of
[limen's book](https://github.com/farcloser/limen/tree/main/book); this is
the mechanics. macOS only: the key lives in the Secure Enclave.

Before running it, three manual steps:

1. **A machine-user GitHub account** for the bot (one per person is allowed by
   GitHub's terms), with two-factor auth. Invite it as an **outside
   collaborator** with write access on the repositories it may push to —
   never as an org member, so it inherits no org-wide defaults.
2. **[taciturn](https://github.com/forkcloser/taciturn)** installed and its agent
   loaded (`taciturn install`), and a key created for the bot that signs
   without a prompt, allowed for `git@github.com` and for the `git` sshsig
   namespace (`taciturn key create` with the fork's `ssh` and `ssh-keygen` as
   its peers, `key allow`, `key sshsig`) — the
   repository rulesets (pull requests, signed commits) are the veto, not a
   touch the human ends up performing blindly. Its public key,
   `taciturn key list --format ssh`, goes to a file. A machine still on
   Secretive names that agent's socket with `--socket`.
3. That public key registered on the bot's GitHub account **twice**: as an
   authentication key and as a signing key.

Then:

```bash
./limen-install-agent <bot-login> <bot-email> <public-key-file>
```

What it does (idempotent — re-run to converge):

- **ProxyCommand helper**: `~/.claude/bin/ssh-connect-proxy`, an authenticated
  HTTP CONNECT tunnel through the sandbox's egress proxy. The sandbox's own ssh
  wiring uses an unauthenticated `nc`, which its proxy refuses.
- **Signing wrapper**: `~/.claude/bin/ssh-keygen-agent`, the toolset's `ssh-keygen`
  (forkcloser/openssh, by its real path: a session's hermetic root carries no openssh,
  so the toolset's link resolves nothing there) with the agent socket pinned inside
  it. The sandbox rewrites
  `SSH_AUTH_SOCK` to a launchd socket it then denies — even when
  `settings.json` sets it — so the socket has to travel inside what git
  execs: this wrapper for signing, `-o IdentityAgent` in `core.sshCommand`
  for ssh.
- **Pinned host keys**: `~/.claude/known_hosts`, GitHub's keys from its
  published list — the sandbox is denied `~/.ssh`, and there is no
  trust-on-first-use.
- **Claude Code settings** (`~/.claude/settings.json`, merged, backed up):
  the agent socket allowed into the sandbox and its key store
  (`~/Library/Application Support/taciturn/keys`) denied to it, and one variable,
  `GIT_CONFIG_GLOBAL`, naming the sessions' git configuration.
- **The sessions' git configuration** (`~/.claude/gitconfig`, rewritten whole on every
  run, readable and not writable by a session like the gh token beside it): name,
  email, signing key, the signing wrapper as `gpg.ssh.program`, `core.sshCommand`
  running the toolset's `ssh` by real path with the agent pinned and the bot key's
  algorithm as the one accepted (the fork's default list carries no ECDSA), the
  `git c` alias, an empty excludes file
  (git's default under `~/.config` is denied to sessions), `push.autosetupremote`
  off (the harness protects every `.git/config` under a session's root), and the
  gh credential helper for https reads. With `GIT_CONFIG_GLOBAL` set, a session's
  git never reads the human's `~/.gitconfig` or `~/.config/git`, so neither needs to
  be readable and the human's config may live wherever it likes. The toolset comes
  first, `limen-install` has run; and this script runs again after an openssh bump
  moves the path (hermetic keeps the old version until it is pruned, so nothing
  breaks in between).
- **The sessions' tool root** (`--agent-root`, default `~/.local/share/limen-agent`):
  a hermetic root of their own, a home for the verifiers, and the Go, cargo and
  XDG caches, all a session may write, so nothing a sandboxed command writes is
  ever executed outside the sandbox. A session may always write its own working
  directory, so a session started in a checkout is confined to that checkout;
  `--write DIR`, optional and repeatable, adds a directory exactly as given, for a
  machine where sessions must reach beyond their own root. The settings `env`
  points `HERMETIC_ROOT_DIR`, `GOPATH`, `GOMODCACHE`, `GOCACHE`, `CARGO_HOME`,
  `XDG_CACHE_HOME` and `LIMEN_AGENT_HOME` (the home: slsa-verifier keeps its TUF
  cache under `$HOME/.sigstore` and reads no other variable) into the root; the
  sandbox's write list becomes the root plus any `--write` directories, and the
  human's tool roots, Go caches, cargo and sigstore cache leave it. The sessions'
  hermetic root gets the toolset's pins, copied from the machine's root, and a
  `bin/hermetic` that is a symlink to the machine's binary, never a copy: every
  link hermetic plants in a root's `bin` points at that root's `bin/hermetic`, it
  links nothing into a root that has none, and the symlink follows the nightly
  bump where a copy stays the version of the day. Nothing per repository: a
  session approves a checkout's policy and installs its pins itself, into the
  root. A session's `PATH` is left alone: the harness writes
  its own process `PATH` into the shell snapshot as a literal, so no rc file can
  put the root first; the machine root's `bin` stays first, read-only to sessions,
  and its one binary dispatches into the sessions' root through
  `HERMETIC_ROOT_DIR`. A tool linked only in the sessions' root is reached through
  `just`. The `permissions.deny`
  baseline is written in full, in `~` form: Read denials on the home's credential
  stores (never the keychain, which gh needs), Edit denials on every dotfile
  letter that holds no sandbox write location, on the launch agents and app data,
  and on each project's own settings and hooks; Read and Edit rules also become
  sandbox denials for every command. The sandbox baseline follows: the reviewed
  network allowlist and deny list (added to, never pruned), no mach service, Apple
  events off, the one exclusion (UTM's `utmctl` by absolute path), and the harness
  settings that go with it (transcripts kept a week, no background traffic; bypass
  mode cannot be refused from user settings). The hand-kept hook that auto-allowed
  sandboxed commands is dropped from the settings (the sandbox auto-allows them
  itself); its file is left for the human.
- **Verification**: the agent serves the key, and GitHub authenticates it as
  the bot.

Inside a session, the agent then uses `git c push` (`git c fetch`, …): the
sandbox exports a `GIT_SSH_COMMAND` that outranks `core.sshCommand`, and the
alias drops it for that one command.

Remaining, per repository: the bot's line in `.allowed_signers`, so
`just lint`'s commit check verifies its signatures — the script prints it.

## After bootstrapping

Scaffold a new repository with:

```bash
limen bootstrap [-license id] [-holder name] <path>
```

(bootstrap authorizes the repository's policy and installs the pinned
tooling itself). For an existing repository, from its root, until its limen
carries `.hermetic/` (then `hermetic policy allow && hermetic install -l`):

```bash
aqua policy allow && aqua install --only-link
```
