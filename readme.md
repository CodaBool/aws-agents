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

# Layout
| path | what |
|---|---|
| `Containerfile` | Fedora bootc image (arm64, t4g) published to `ghcr.io/codabool/aws-agents:latest` |
| `rootfs/` | copied into the image: ec2-user, linger, first boot quadlet clone, daily bootc updates, podman prune |
| `quadlets/` | the only part of this repo the host runs, cloned to `~/src/agent` and linked as `~/.config/containers/systemd` |
| `main.tf` | EC2 instance, applied locally only |
| `vm` | local testing |
| `tests` | image checks, `just test` and CI |

# Secrets

Stored in SSM written to disk on startup

```sh
IP=...
TUNNEL_TOKEN=...
DISCORD_TOKEN=...
```

# Services
```md
├── tunnel:latest
└── webtop:debian-i3
```

# Local Test
```sh
just test       # build arm64 + smoke test
just vm         # bib qcow2 + qemu, then `just ssh` in another terminal
just ami        # bib AMI from ghcr :latest, uploaded as agents-<date>
```

# Fedora Upgrade Guide

```diff
# Containerfile
-FROM quay.io/fedora/fedora-bootc:44
+FROM quay.io/fedora/fedora-bootc:45
```


# Quick Start
1. just init
2. just bootstrap
3. just ami
4. just key
5. just apply
6. just ssh-ec2


# Replace Server Fully
1. just ami
2. just rebuild

# todo
- optimize storage cost & remove ipv4
