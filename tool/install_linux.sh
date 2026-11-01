#!/bin/sh
# Builds fluttAIrbar for Linux and installs it for this user, the way the
# README describes:
#   ~/.local/opt/fluttairbar     the app bundle (the previous one is kept as
#                                fluttairbar.bak-TIME next to it)
#   ~/.local/bin/fluttairbar     a link to the app
#   ~/.local/bin/fluttairbar-cli the command line
# Run it from anywhere; run it again after updating the checkout.
set -eu
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Linux ] || { echo "this script installs the Linux build; see the README for macOS and Windows" >&2; exit 2; }
flutter pub get >/dev/null
flutter build linux --release
arch=$(ls build/linux | head -n1)
opt="$HOME/.local/opt/fluttairbar"
if [ -d "$opt" ]; then cp -a "$opt" "$opt.bak-$(date +%Y%m%d-%H%M%S)"; fi
mkdir -p "$opt" "$HOME/.local/bin"
rsync -a --delete "build/linux/$arch/release/bundle/" "$opt/"
ln -sfn "$opt/fluttairbar" "$HOME/.local/bin/fluttairbar"
dart compile exe tool/fluttairbar_cli.dart -o "$HOME/.local/bin/fluttairbar-cli.new" >/dev/null
mv -f "$HOME/.local/bin/fluttairbar-cli.new" "$HOME/.local/bin/fluttairbar-cli"
echo "installed $opt, ~/.local/bin/fluttairbar and ~/.local/bin/fluttairbar-cli"
