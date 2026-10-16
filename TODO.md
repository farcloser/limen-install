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
- **Signing across the fleet, and Apple notarization.** What is signed today:
  every release's `checksums.txt` with cosign, keyless in CI (limen's canonical
  lane); `Taciturn.app` with the team's Developer ID identity and a provisioning
  profile, in its own bundle script on a macOS runner, not notarized by design
  (aqua downloads carry no quarantine attribute and the tool runs by path);
  ossein and openssh ad hoc, which Gatekeeper cannot notarize. Nothing else.
  Notarizing the Go binaries needs no macOS runner: goreleaser's `notarize.macos`
  (open source, `anchore/quill`, any OS) signs and notarizes binaries from a
  Developer ID Application `.p12` and an App Store Connect API key, entitlements
  included, binaries only and never app bundles, so taciturn's bundle keeps its
  native path. The Apple account and the certificate already exist for taciturn.
  To decide: whether the toolset's binaries, fetched through hermetic without
  quarantine, gain anything from it; whether a long-lived Apple certificate
  belongs in lanes that are keyless today; which repositories opt in, as a
  `notarize.macos` block in their `.release-go.yaml` plus two organisation
  secrets; and whether one signing policy should be written for the fleet (what
  is signed with what, and what a consumer verifies) instead of per repository.
