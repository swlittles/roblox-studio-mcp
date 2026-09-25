#!/bin/zsh
# Installs dependencies, the pinned Luau compiler used for play-test sessions, the window capture helper,
# and builds the StudioBridge plugin into ~/Documents/Roblox/Plugins.
set -e
ROOT=${0:A:h:h}
cd "$ROOT"
mkdir -p bin
fetch() { local tmp=$(mktemp -d); curl -sfL -o "$tmp/a.zip" "$1" && unzip -oq "$tmp/a.zip" -d "$2"; rm -rf "$tmp"; }
[[ -x bin/rojo ]] || fetch https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-macos-aarch64.zip bin
if [[ ! -x bin/luau-compile-bc6 ]]; then
  # Fiu (the bundled bytecode VM) understands bytecode v3-6, which Luau 0.700 still emits.
  tmp=$(mktemp -d); fetch https://github.com/luau-lang/luau/releases/download/0.700/luau-macos.zip "$tmp"
  cp "$tmp/luau-compile" bin/luau-compile-bc6; rm -rf "$tmp"
fi
swiftc -O -o bin/studio-snap native/studio-snap.swift
npm install --silent
"$ROOT/scripts/build-plugin.sh"
echo "roblox-studio-bridge ready. Register: node $ROOT/server.mjs"
