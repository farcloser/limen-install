# To explore

Open ideas for the rig, not scheduled. Each becomes an issue or a pull request
when someone takes it.

- **A separate Unix account for the sessions.** The sandbox allowlists writes
  but can only deny reads one path at a time; file permissions on the human's
  home would be the read allowlist it lacks. Sessions would run as `claude`
  processes in the second account, driven from the desktop app through Remote
  Control (untried across two local accounts). Costs: separate clones per
  account, with git as the bridge, or a shared working tree with a group,
  setgid directories and ACLs; a live login for the account, since Secretive
  with its own Enclave key, UTM, Docker Desktop and Homebrew are per user.
  Worth it only with separate clones.
