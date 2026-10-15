# https://en.wikipedia.org/wiki/Fedora_Linux_release_history
FROM quay.io/fedora/fedora-bootc:44

# lets GITHUB_TOKEN push to the package and links it to the repo
LABEL org.opencontainers.image.source=https://github.com/CodaBool/aws-agents

# cloud-init creates ec2-user's ~/.ssh from the EC2 key pair (and the NoCloud seed in `just vm`)
RUN dnf install -y git cloud-init && dnf clean all && rm -rf /var/cache/* /var/log/* /var/lib/dnf /var/lib/cloud /run/dnf /run/cloud-init \
  && ln -s ../cloud-init.target /usr/lib/systemd/system/default.target.wants/cloud-init.target

COPY rootfs/ /

# ec2-user (uid 1000) is defined in sysusers.d; create it now so /etc/passwd ships with it
# useradd normally writes subuid/subgid, sysusers does not, rootless podman needs them
RUN systemd-sysusers \
  && echo "ec2-user:524288:65536" >> /etc/subuid \
  && echo "ec2-user:524288:65536" >> /etc/subgid

# system units
RUN systemctl enable bootc-fetch-apply-updates.timer agent-quadlets-clone.service

# user units, enabled for every user (only ec2-user lingers)
RUN systemctl --global enable podman.socket podman-auto-update.timer podman-prune.timer

RUN bootc container lint --fatal-warnings
