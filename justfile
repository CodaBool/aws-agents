image := "ghcr.io/codabool/aws-agents:latest"
bib := "quay.io/centos-bootc/bootc-image-builder:latest"
region := "us-east-1"
# created by main.tf (`just bootstrap`)
bucket := "codabool-agents-ami-import"

# t4g = arm64, on x86 this builds under qemu-user-static emulation
build:
  podman build --arch arm64 --pull=newer -t {{image}} .

# lint, units enabled, user + linger, quadlets parse
test: build
  tests/smoke.sh {{image}} --arch arm64

run: build
  podman run --rm --arch arm64 --name agent {{image}} tail -f /dev/null

exec:
  podman exec -it agent bash

stop:
  podman rm -f agent

# CI does this on push to main, this is for a quick manual push (assuming you are logged in)
upload: test
  podman push {{image}}

# local VM from the local build: bib qcow2 + NoCloud seed with your key, qemu in a container
# boot takes a few minutes under emulation, then `just ssh` (Ctrl-a x quits qemu)
vm: test vm-tools
  podman save {{image}} | sudo podman load
  just _bib qcow2
  rm -f output/seed.iso
  printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat ~/.ssh/id_ed25519.pub)" > output/user-data
  printf 'instance-id: agent-vm\nlocal-hostname: agent-vm\n' > output/meta-data
  podman run --rm -v ./output:/output:z localhost/agent-vm \
    xorriso -as mkisofs -quiet -o /output/seed.iso -V cidata -J -r /output/user-data /output/meta-data
  podman run --rm -it -v ./output:/output:z -p 127.0.0.1:2222:2222 localhost/agent-vm \
    qemu-system-aarch64 -M virt -cpu max -smp 4 -m 4096 -nographic \
    -bios /usr/share/edk2/aarch64/QEMU_EFI.fd \
    -drive file=/output/qcow2/disk.qcow2,if=virtio,format=qcow2 \
    -drive file=/output/seed.iso,if=virtio,format=raw,readonly=on \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22

# checks once logged in:
#   systemctl status agent-quadlets-clone; ls -l ~/.config/containers/systemd
#   loginctl show-user ec2-user -p Linger; systemctl --user list-timers; systemctl --user status uptime
ssh:
  ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@localhost

vm-tools:
  podman build -t localhost/agent-vm vm/

# AMI from what is published on GHCR (what hosts track), named agents-<date> for main.tf
# needs AWS creds (`aws login`) and `just bootstrap` once for the S3 bucket + vmimport role
ami:
  sudo podman pull --arch arm64 {{image}}
  mkdir -p output && umask 077 && aws configure export-credentials --format env-no-export > output/.aws.env
  just _bib ami --aws-ami-name agents-$(date +%Y%m%d-%H%M) --aws-bucket {{bucket}} --aws-region {{region}} ; rc=$?; rm -f output/.aws.env; exit $rc

# bootc-image-builder must run rootful, reads the image from root's container storage
_bib type *args:
  mkdir -p output
  sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    $([ -f output/.aws.env ] && echo --env-file output/.aws.env) \
    {{bib}} \
    --type {{type}} --target-arch aarch64 --rootfs xfs --chown $(id -u):$(id -g) \
    {{args}} {{image}}

# terraform is only applied locally
init:
  tofu init

# the AMI import bucket + vmimport role must exist before `just ami`
bootstrap:
  tofu apply -target=aws_s3_bucket.ami_import -target=aws_s3_bucket_public_access_block.ami_import -target=aws_s3_bucket_lifecycle_configuration.ami_import -target=aws_iam_role_policy.vmimport

# EC2 key pair `agents` (main.tf key_name) from ~/.ssh/agents, needed before the instance is created
# cloud-init puts it in ec2-user's authorized_keys
key:
  #!/usr/bin/env bash
  set -euo pipefail
  [ -f ~/.ssh/agents ] || ssh-keygen -t ed25519 -C agents -f ~/.ssh/agents
  if aws ec2 describe-key-pairs --region {{region}} --key-names agents >/dev/null 2>&1; then
    echo "key pair agents already exists in {{region}}, delete it first if it is not ~/.ssh/agents.pub"
  else
    aws ec2 import-key-pair --region {{region}} --key-name agents --public-key-material fileb://$HOME/.ssh/agents.pub
  fi

# ssh to the EC2 instance, `just ssh-ec2 ipv4` if you are not on ipv6
ssh-ec2 family="ipv4":
  ssh -i ~/.ssh/agents ec2-user@$(tofu output -raw {{family}})

plan:
  tofu plan

# AMIs are only needed to create the instance, it updates in place from GHCR after that
apply:
  tofu apply
  just ami-clean

# deregister every agents-* AMI and delete its snapshot (~$0.05/GB-month), `just ami` makes a new one when needed
ami-clean:
  #!/usr/bin/env bash
  set -euo pipefail
  ids=$(aws ec2 describe-images --region {{region}} --owners self --filters "Name=name,Values=agents-*" --query "Images[].ImageId" --output text)
  for id in $ids; do
    echo "deregistering $id + snapshots"
    aws ec2 deregister-image --region {{region}} --image-id "$id" --delete-associated-snapshots >/dev/null
  done
