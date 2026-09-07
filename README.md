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

## Versioning

There are no tags. The scripts are consumed by cloning this repository, or
through [homebrew-brews](https://github.com/farcloser/homebrew-brews)'
`Formula/limen.rb`, which pins a `revision` of this repository and is bumped
by hand.

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
- **Pinned host keys**: `~/.claude/known_hosts`, GitHub's keys from its
  published list — the sandbox is denied `~/.ssh`, and there is no
  trust-on-first-use.
- **Claude Code settings** (`~/.claude/settings.json`, merged, backed up):
  the Secretive socket allowed into the sandbox, `SSH_AUTH_SOCK` pointing at
  it, and the bot identity as session-scoped git configuration — name, email,
  signing key, Apple's `ssh-keygen` (the Homebrew OpenSSH is built without
  OpenSSL and cannot use an ECDSA key), `core.sshCommand`, and a `git c`
  alias. The human's own git config is never touched.
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
