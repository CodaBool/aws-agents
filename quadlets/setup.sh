#!/usr/bin/env bash
# installs node, godot and claude code (+ godot mcp) into /config, the persistent home of the webtop container
# run as abc from a webtop terminal: bash /opt/webtop/setup.sh
# safe to rerun: up-to-date tools are skipped, newer releases replace the old ones
# everything goes in the home dir, apt installs would be lost on the next image update
set -euo pipefail

[ "$(id -u)" != 0 ] || { echo "run as abc, not root"; exit 1; }

case $(uname -m) in
  x86_64) node_arch=x64; godot_arch=x86_64 ;;
  aarch64) node_arch=arm64; godot_arch=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

apps=$HOME/apps
bin=$HOME/.local/bin
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$apps" "$bin"
export PATH="$bin:$PATH"
# shellcheck disable=SC2016 # literal $HOME/$PATH, expanded by bash at login
grep -q '.local/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

echo "== node"
ver=$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c 'import json,sys; print(next(r["version"] for r in json.load(sys.stdin) if r["lts"]))')
if [ "$(node --version 2>/dev/null)" = "$ver" ]; then
  echo "node $ver up to date"
else
  curl -fsSL "https://nodejs.org/dist/$ver/node-$ver-linux-$node_arch.tar.gz" -o "$tmp/node.tar.gz"
  rm -rf "$apps/node" && mkdir "$apps/node"
  tar -xzf "$tmp/node.tar.gz" -C "$apps/node" --strip-components=1
  ln -sf "$apps/node/bin/node" "$apps/node/bin/npm" "$apps/node/bin/npx" "$bin/"
  echo "node $ver installed"
fi

echo "== godot"
# the linux zip holds a single binary, e.g. Godot_v4.5-stable_linux.arm64
url=$(curl -fsSL https://api.github.com/repos/godotengine/godot/releases/latest | grep -o "https://[^\"]*linux\.$godot_arch\.zip")
name=$(basename "$url" .zip)
if [ -x "$apps/godot/$name" ]; then
  echo "$name up to date"
else
  curl -fsSL "$url" -o "$tmp/godot.zip"
  rm -rf "$apps/godot"
  python3 -m zipfile -e "$tmp/godot.zip" "$apps/godot"
  chmod +x "$apps/godot/$name"
  ln -sf "$apps/godot/$name" "$bin/godot"
  echo "$name installed"
fi

echo "== claude code"
# the native install updates itself, only install when missing or unable to run
# (e.g. a musl build left in /config by an alpine webtop: "required file not found")
if v=$(claude --version 2>/dev/null); then
  echo "claude $v present"
else
  # drop the binaries only, ~/.claude and ~/.claude.json (login, mcp servers) are kept
  rm -rf "$bin/claude" ~/.local/share/claude
  curl -fsSL https://claude.ai/install.sh | bash
fi

# user scope: available from any directory. GODOT_PATH is the symlink, so godot upgrades need no change
if claude mcp get godot >/dev/null 2>&1; then
  echo "godot mcp present"
else
  claude mcp add --scope user godot -e GODOT_PATH="$bin/godot" -- npx -y @coding-solo/godot-mcp
fi

echo "== cleanup"
# downloads are in $tmp (removed on exit). npm's download cache is safe to drop,
# ~/.npm/_npx is kept so the godot mcp does not redownload on every claude start
npm cache clean --force 2>/dev/null || true
rm -rf ~/.cache/pip ~/.cache/thumbnails
du -sh "$apps"/* ~/.local/share/claude ~/.npm 2>/dev/null || true
echo "done, open a new terminal so PATH picks up ~/.local/bin"
