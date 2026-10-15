#!/usr/bin/env bash
# fast smoke test of the built image, used by `just test` and CI
# usage: tests/smoke.sh <image> [podman run args...]
set -euo pipefail
image=$1; shift
repo=$(cd "$(dirname "$0")/.." && pwd)

podman run --rm "$@" -v "$repo/quadlets:/quadlets:ro,z" "$image" bash -euo pipefail -c '
  echo "== bootc container lint"
  bootc container lint

  echo "== packages"
  rpm -q git cloud-init podman

  echo "== ec2-user"
  getent passwd ec2-user | grep -q "^ec2-user:x:1000:1000:.*:/var/home/ec2-user:/bin/bash$"
  id -nG ec2-user | grep -qw wheel
  grep -q "^ec2-user:" /etc/subuid
  grep -q "^ec2-user:" /etc/subgid
  grep -q "linger/ec2-user" /usr/lib/tmpfiles.d/ec2-user.conf

  echo "== system units enabled"
  for u in bootc-fetch-apply-updates.timer agent-quadlets-clone.service cloud-init.target; do
    printf "%-40s %s\n" "$u" "$(systemctl is-enabled "$u")"
    systemctl is-enabled -q "$u"
  done

  echo "== user units enabled"
  for u in podman.socket podman-auto-update.timer podman-prune.timer; do
    printf "%-40s %s\n" "$u" "$(systemctl --global is-enabled "$u")"
    systemctl --global is-enabled -q "$u"
  done

  echo "== bootc update timer is daily"
  systemctl cat bootc-fetch-apply-updates.timer 2>/dev/null | grep -q "^OnCalendar=" \
    || grep -q "^OnCalendar=" /usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/*.conf

  echo "== unit files verify"
  systemd-analyze verify --man=no \
    /usr/lib/systemd/system/agent-quadlets-clone.service \
    /usr/lib/systemd/user/podman-prune.service \
    /usr/lib/systemd/user/podman-prune.timer

  echo "== quadlets parse"
  out=$(QUADLET_UNIT_DIRS=/quadlets /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun 2>&1) \
    || { echo "$out"; exit 1; }
  if grep -qiE "error|warn" <<<"$out"; then echo "$out"; exit 1; fi
  grep -E "^---.*---$" <<<"$out"

  echo "== OK"
'
