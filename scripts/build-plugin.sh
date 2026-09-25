#!/bin/zsh
# Builds the StudioBridge plugin into Studio's local plugins folder. Studio loads it for new places and
# play tests; edit sessions can pick up Core.luau changes with the reload_plugin tool.
set -e
ROOT=${0:A:h:h}
mkdir -p ~/Documents/Roblox/Plugins
"$ROOT/bin/rojo" build "$ROOT/plugin.project.json" -o ~/Documents/Roblox/Plugins/StudioBridge.rbxm
