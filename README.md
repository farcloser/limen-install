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
- **aqua**: installed (pinned, checksum-verified) if absent; an already-present
  aqua is converged to the pinned version.
- **shell config**: your `PATH` and `AQUA_GLOBAL_CONFIG` are appended to your shell rc
  only if missing. If anything changed, open a new shell to pick it up.
- **global config**: the aqua global config is written with `limen` as its sole package.
- **tools**: `aqua install --all` installs limen.

## The toolset

The global aqua config pins the machine toolset: `limen`, and on macOS/arm64
[forkcloser/openssh](https://github.com/forkcloser/openssh) — OpenSSH with security keys
built in (`ssh`, `ssh-agent`, `ssh-add`, `ssh-keygen`, `ssh-keyscan`, `scp`, `sftp`,
`ssh-agent-install`); aqua skips it elsewhere. Renovate moves both pins here, and a tag ships
them to every machine the next night. The ssh-agent launchd agent (`org.forkcloser.ssh_agent`)
is part of the toolset: it runs the package by its real path, so whenever the loaded agent is
not the pinned package — none loaded, an older one, a hand-unpacked one — the script runs the
package's `ssh-agent-install`, which installs and starts it. `LIMEN_INSTALL_NO_LAUNCHD=1`
makes a run load no service — neither the agent nor the nightly job; their files are still
written — for a test in a throwaway HOME on a machine with a real agent.

## The nightly update job (macOS)

The first run installs a launchd agent, `world.farcloser.limen-install`, that re-runs the
latest release of this script every night (04:17 local; log in
`~/Library/Logs/limen-install.log`). It fetches the script over plain https from the
release tag — no clone, no credential, no key: the trust is TLS to github.com and the
ruleset that lets only the repository's admins create a `v*` tag — and runs it with the
system's tools first on `PATH` and aqua's variables exported, since launchd sources no rc.
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
2. **[Secretive](https://github.com/maxgoedjen/secretive)** installed, its agent
   (SecretAgent) enabled, and a key created for the bot with **"Requires
   authentication" off** — the repository rulesets (pull requests, signed
   commits) are the veto, not a touch the human ends up performing blindly.
   Export its public key to a file.
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
- **Signing wrapper**: `~/.claude/bin/ssh-keygen-agent`, Apple's `ssh-keygen`
  with the Secretive socket pinned inside it. The sandbox rewrites
  `SSH_AUTH_SOCK` to a launchd socket it then denies — even when
  `settings.json` sets it — so the socket has to travel inside what git
  execs: this wrapper for signing, `-o IdentityAgent` in `core.sshCommand`
  for ssh.
- **Pinned host keys**: `~/.claude/known_hosts`, GitHub's keys from its
  published list — the sandbox is denied `~/.ssh`, and there is no
  trust-on-first-use.
- **Claude Code settings** (`~/.claude/settings.json`, merged, backed up):
  the Secretive socket allowed into the sandbox, and the bot identity as
  session-scoped git configuration — name, email, signing key, the signing
  wrapper as `gpg.ssh.program` (the Homebrew OpenSSH is built without OpenSSL
  and cannot use an ECDSA key; Apple's can), `core.sshCommand` with the agent
  pinned, and a `git c` alias. The human's own git config is never touched.
- **The sessions' tool root** (`--agent-root`, default `~/.local/share/limen-agent`):
  aqua's root, a home for the verifiers, and the Go, cargo and XDG caches, all a
  session may write, so nothing a sandboxed command writes is ever executed
  outside the sandbox. `--write DIR` is required and repeatable: a directory
  sessions may write, exactly as given, where the checkouts live; no default, the
  layout is the machine's. The settings `env` points `AQUA_ROOT_DIR`, `GOPATH`,
  `GOMODCACHE`, `GOCACHE`, `CARGO_HOME`, `XDG_CACHE_HOME` and `LIMEN_AGENT_HOME`
  (the home: slsa-verifier keeps its TUF cache under `$HOME/.sigstore` and reads
  no other variable) into the root; the sandbox's write list becomes the `--write`
  directories plus the root, and the human's aqua root, Go caches, cargo and
  sigstore cache leave it. The root gets aqua at the machine's version and nothing
  per repository: a session approves a checkout's policy and installs its pins
  itself, into the root. A session's `PATH` is left alone: the harness writes its
  own process `PATH` into the shell snapshot as a literal, so no rc file can put
  the root first; the human's aqua `bin` stays first, read-only to sessions, and
  its proxies run the root's packages through `AQUA_ROOT_DIR`. A tool linked only
  in the root is reached through `just` or `aqua exec`. `permissions.deny`
  rules keep the file tools (Edit, Write) out of every dotfile and dot
  directory of the home, the launch agents, and each project's own settings
  and hooks: the sandbox binds Bash only, and a deny rule beats every allow.
  The hand-kept hook that auto-allowed sandboxed commands is dropped from the
  settings (the sandbox auto-allows them itself); its file is left for the human.
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

(bootstrap authorizes the repository's aqua policy and installs the pinned
tooling itself). For an existing repository, from its root:

```bash
aqua policy allow && aqua install --only-link
```
