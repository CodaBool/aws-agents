# EC2 Agent
<a href="https://www.youtube.com/watch?v=2H5lqPRPNhA">
  <img src="https://github.com/CodaBool/stargazer/blob/main/public/pom.gif?raw=true" style="height:70px;">
</a>

```
         .--"--.           
       / -     - \         
      / (O)   (O) \        
   ~~~| -=(,Y,)=- |       
    .---. /`  \   |~~      
 ~/  o  o \~~~~.----. ~~  don't talk to us    
  | =(X)= |~  / (O (O) \   
   ~~~~~~~  ~| =(Y_)=-  |   
  ~~~~    ~~~|   U      |~~ 
```

## Security
- [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks) provided by the tunnel container
- security group only allows SSH (`agents` key pair, `ec2-user`) from two IPv6 addresses

## Layout
| path | what |
|---|---|
| `Containerfile` | Fedora bootc image (arm64, t4g) published to `ghcr.io/codabool/aws-agents:latest` |
| `rootfs/` | copied into the image: ec2-user, linger, first boot quadlet clone, daily bootc updates, podman prune |
| `quadlets/` | the only part of this repo the host runs, cloned to `~/src/agent` and linked as `~/.config/containers/systemd` |
| `main.tf` | EC2 instance + AMI import bucket/role, applied locally only |
| `tests/smoke.sh` | image checks, `just test` and CI |

## Automatic Updates
- **OS**: `bootc-fetch-apply-updates.timer` daily at 09:00 UTC, pulls `ghcr.io/codabool/aws-agents:latest` and reboots if there is a new image
- **image**: CI rebuilds on push to main and weekly (Fedora updates)
- **containers**: add `AutoUpdate=registry` to the `.container` file, user `podman-auto-update.timer` runs daily
- **cleanup**: user `podman-prune.timer` removes dangling images daily

## Automatic run on boot
ec2-user lingers (tmpfiles.d), so the user manager and every quadlet with `WantedBy=default.target` starts on boot

## Quadlets
First boot clones this repo to `~/src/agent` (`agent-quadlets-clone.service`) and links `~/.config/containers/systemd` → `~/src/agent/quadlets`. After that update manually:
```sh
cd ~/src/agent && git pull && systemctl --user daemon-reload   # or the `pull` alias
```
Data is in named volumes (`~/.local/share/containers/storage/volumes`), `/var` survives bootc updates.

The tunnel needs its token once:
```sh
mkdir -p ~/.config/agent && install -m 600 /dev/null ~/.config/agent/tunnel.env
echo "TUNNEL_TOKEN=..." > ~/.config/agent/tunnel.env && systemctl --user restart tunnel
```

## Expose Podman socket
`podman.socket` is enabled for every user (`systemctl --global`), at `/run/user/1000/podman/podman.sock`

# Services
> I use changedetector to find any changes to any pinned image tags

```md
├── uptime:2
├── tunnel:latest
```

---

# Bootable Container
### Commands
- bootc upgrade --check (check for a new image)
- bootc upgrade --apply (will restart into new image)
- bootc status (see info about current image)

### Local
```sh
just test       # build arm64 + smoke test
just vm         # bib qcow2 + qemu, then `just ssh` in another terminal
just ami        # bib AMI from ghcr :latest, uploaded as agents-<date>
just plan / just apply
```

### First deploy
```sh
# 1. push this repo to github.com/CodaBool/aws-agents (public), CI pushes the image
#    then make the ghcr package public: github.com/CodaBool/aws-agents/pkgs/container/aws-agents > settings
# 2. AMI import bucket + vmimport role, once
aws login
just init && just bootstrap
# 3. AMI
just ami
# 4. instance, then deletes the AMI + snapshot (only needed to create the instance)
just apply
ssh ec2-user@$(tofu output -raw ipv6)
```

### Links
- [bootc-image-builder](https://github.com/osbuild/bootc-image-builder)
- [bootc docs](https://containers.github.io/bootc)
- [quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)

---

# bashrc
> baked into the image as `/etc/profile.d/agent.sh`, the functions below are not

```sh
alias large="find . -type f -size +50M -exec du -h {} \; | sort -n"
alias size="du -sh -- *"
alias c="cd ~/src/agent/quadlets && ls -lah"
alias v="cd ~/.local/share/containers/storage/volumes && ls -lah"
alias reload="systemctl --user daemon-reload"
alias r="systemctl --user daemon-reload && systemctl --user restart $@"
alias s="systemctl --user daemon-reload && systemctl --user stop $@"
alias f="podman logs -f $@"
alias e="podman logs $@"
alias debug="systemd-analyze --user --generators=true verify \$@"
alias valid="systemd-analyze --user --generators=true verify \$@"

podunzip() {
  local zip_file="$1"
  local out_dir="$2"

  if [ -z "$zip_file" ] || [ -z "$out_dir" ]; then
    echo "Usage: podunzip ./file.zip output-folder"
    return 1
  fi

  if [ ! -f "$zip_file" ]; then
    echo "Zip file not found: $zip_file"
    return 1
  fi

  mkdir -p "$out_dir"

  podman run --rm \
    -v "$PWD:/work:rw" \
    -w /work \
    --security-opt label=disable \
    docker.io/library/debian:trixie-slim \
    sh -c 'apt-get update >/dev/null && apt-get install -y unzip >/dev/null && unzip -o "$1" -d "$2"' \
    sh "$zip_file" "$out_dir"
}

p() {
    local DRY=false
    if [[ "$1" == "--dry" ]]; then
        DRY=true
    fi

    local TARGET="../$(basename "$PWD")"

    local CHOWN_CMD="sudo chown -R 1000:1000 \"$TARGET\""
    local CHMOD_CMD="sudo chmod -R 755 \"$TARGET\""

    if [[ "$DRY" == true ]]; then
        echo "[Dry Run] Would execute:"
        echo "  $CHOWN_CMD"
        echo "  $CHMOD_CMD"
    else
        echo "Executing:"
        echo "  $CHOWN_CMD"
        eval "$CHOWN_CMD"

        echo "  $CHMOD_CMD"
        eval "$CHMOD_CMD"
    fi
}
```

# General Dev Notes
- [plasma bigscreen](https://invent.kde.org/plasma/plasma-bigscreen), buy a intel nuc kit put bazzite on it.

# upgrade guide

```diff
# ./Containerfile
-FROM quay.io/fedora/fedora-bootc:44
+FROM quay.io/fedora/fedora-bootc:45
```

```sh
git push   # CI builds + pushes :latest
ssh ec2-user@<ipv6>
sudo bootc upgrade --apply   # or wait for the daily timer
cat /etc/os-release
```
