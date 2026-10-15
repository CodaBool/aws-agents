# aws-agents

Fedora bootc image for one EC2 t4g (arm64) host that runs rootless podman quadlets as `ec2-user`.
Repo `github.com/CodaBool/aws-agents` (public). Image `ghcr.io/codabool/aws-agents:latest` (public, lowercase).

## Update paths
- OS: CI pushes `:latest` → host `bootc-fetch-apply-updates.timer` (daily 09:00 UTC, drop-in in `rootfs/`) runs `bootc upgrade --apply` and reboots.
- Quadlets: never shipped in the image. Host clones the repo once; after that the user runs `git pull && systemctl --user daemon-reload` by hand.
- App images: `AutoUpdate=registry` in each quadlet + user `podman-auto-update.timer`; user `podman-prune.timer` removes the dangling leftovers.
- The instance is never replaced for updates. A new AMI only matters when creating an instance.

## Image rules
- `/var` is populated only at install. Anything under `/var` (home dirs, linger file) is created by `rootfs/usr/lib/tmpfiles.d/`. The Containerfile cleans `/var` and `/run` after dnf; `bootc container lint --fatal-warnings` fails the build otherwise.
- `ec2-user` is uid/gid 1000, defined in `rootfs/usr/lib/sysusers.d/` and materialized at build time with `systemd-sysusers` so `/etc/passwd` ships with it. subuid/subgid are appended by hand (sysusers skips them).
- uid 1000 is hardcoded in `agent-quadlets-clone.service` (`After=user@1000.service`) and implied by `%t` paths in quadlets. Keep the uid at 1000.
- User units are enabled with `systemctl --global enable`; only `ec2-user` lingers, so only its manager runs at boot.
- cloud-init owns SSH: it puts the EC2 key pair `agents` (or the NoCloud seed in `just vm`) into `ec2-user`'s authorized_keys and adds the NOPASSWD sudo rule. The image is public: keep it free of keys and secrets.
- Root partition growth is `bootc-generic-growpart.service`; cloud-init growpart/resize are off.
- Host-side secrets live outside the repo, e.g. `~/.config/agent/tunnel.env` (TUNNEL_TOKEN).

## Quadlet layout
- First boot, `agent-quadlets-clone.service` clones the repo to `~/src/agent` and symlinks `~/.config/containers/systemd -> ../../src/agent/quadlets`.
- Quadlet scans recursively, so only `quadlets/` is linked. Put every `.container`/`.volume` there and nowhere else in the repo.
- Persistent data uses named volumes (`*.volume`), stored under the user's storage in `/var`, which survives bootc updates.
- Host paths still say `agent` (`~/src/agent`, `agent-quadlets-clone`) while the repo/image say `aws-agents`. Intentional; changing them requires a migration on the live host.

## AMI and Terraform
- EC2 boots only AMIs, and `ImportSnapshot` only reads from S3. So `just ami` runs bootc-image-builder `--type ami`, which uploads to bucket `codabool-agents-ami-import` and imports via the `vmimport` role. Bucket objects expire after 1 day.
- Bucket name is duplicated in `justfile` and `main.tf`; keep them equal.
- `just bootstrap` creates only the bucket + vmimport role (targeted apply), needed before the first `just ami`.
- Cost target: under $0.10/month for AMI storage. `just apply` = `tofu apply` then `just ami-clean`, which deregisters every `agents-*` AMI and deletes its snapshots.
- `main.tf` uses `data "aws_ami_ids"` (empty list allowed) so plans work with no AMI; `aws_instance.main` has `ignore_changes = [ami]`. Creating or replacing the instance needs `just ami` first.
- bib does not tag AMIs; matching is on name `agents-*` + arm64.
- Terraform is applied locally only, state in S3 bucket `codabool-tf`. The IAM role/profile `agents` has no policies; kept for future use.
- Ask before anything that touches AWS (`tofu apply`, `just ami`, `just bootstrap`, `just ami-clean`) or pushes to GHCR.

## Build and test
- arm64 only. On the x86 workstation builds run under qemu-user-static; CI uses native `ubuntu-24.04-arm`.
- `just test` builds and runs `tests/smoke.sh` (also run by CI): lint, packages, ec2-user, enabled units, daily timer, `systemd-analyze verify`, quadlet dry-run against `quadlets/`. Extend `smoke.sh` when adding units or quadlets.
- systemd will not boot as PID 1 in a container under arm64 emulation. First-boot behavior (tmpfiles, linger, clone, cloud-init, SSH) is verifiable only with `just vm` or on EC2.
- bootc-image-builder must run rootful and reads root's container storage: `just vm` copies the local build in (`podman save | sudo podman load`); `just ami` pulls the published image from GHCR. Both need the user's sudo password, so the user runs them.
- `just vm`: qcow2 + NoCloud seed with `~/.ssh/id_ed25519.pub`, qemu-system-aarch64 inside `vm/Containerfile` (host has no qemu); `just ssh` connects on localhost:2222.
- Other checks: `tofu fmt -check`; `tofu validate` after `tofu init -backend=false` in a scratch copy; actionlint via `podman run docker.io/rhysd/actionlint`.

## CI (`.github/workflows/build.yml`)
- Triggers: push to main, weekly Monday 21:00 UTC (Fedora base updates), manual.
- Steps: `podman build --pull=always` → `tests/smoke.sh` → push `:latest` and `:<sha>` with `GITHUB_TOKEN` (the image LABEL links the package to the repo) → GitHub Release tagged with the Fedora version label, updated in place.
- No AWS credentials in CI; AMIs are built locally.

## Fedora version bump
Change `FROM quay.io/fedora/fedora-bootc:<N>` in `Containerfile` only; push; hosts pick it up on the next daily upgrade.
