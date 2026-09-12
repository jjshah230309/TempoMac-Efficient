#!/bin/bash
# Builds Tempo.app — a native SwiftUI macOS app that reads your real Music
# library via Apple's iTunesLibrary framework.
set -e
cd "$(dirname "$0")"

APP="Tempo.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
echo "▸ Cleaning…"; rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp Info.plist "$APP/Contents/Info.plist"

# The app icon. This build wipes and recreates the bundle every time, so an icon
# applied by hand in Finder is destroyed on the next rebuild — it has to live in
# the source tree and be copied in here (before signing, or the signature won't
# cover it). Info.plist points at it via CFBundleIconFile.
cp Tempo.icns "$RES/Tempo.icns"

echo "▸ Compiling Swift…"
swiftc -O \
    -framework iTunesLibrary -framework AuthenticationServices \
    -framework ServiceManagement -framework LocalAuthentication \
    Sources/Model.swift Sources/Theme.swift Sources/ArtistSplitter.swift Sources/Persistence.swift Sources/ArtistArt.swift Sources/HistoryImporter.swift Sources/LastFM.swift Sources/SpotifyAuth.swift Sources/Scrobbler.swift Sources/LibraryStore.swift Sources/Notify.swift Sources/Agent.swift Sources/MiniPlayer.swift Sources/Wrapped.swift Sources/Welcome.swift Sources/TempoApp.swift \
    -o "$MACOS/Tempo"

# The background-scrobbler LaunchAgent plist is written at runtime to
# ~/Library/LaunchAgents and loaded via launchctl (see BackgroundAgent). We do
# NOT use SMAppService here: it validates the helper against a code requirement
# that Tempo's self-signed / no-Team-ID build can't satisfy, so launchd refuses
# to spawn it. A manually-loaded user agent has no such requirement.

# Sign with a STABLE self-signed identity so macOS remembers the Music-library
# permission across launches and rebuilds. Falls back to ad-hoc if the identity
# isn't set up (run ./setup-signing.sh once to create it).
IDENTITY="Tempo Local Signing"
KEYCHAIN="$HOME/Library/Keychains/tempo-signing.keychain-db"
if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "▸ Signing with stable identity ($IDENTITY)…"
    security unlock-keychain -p tempo "$KEYCHAIN" >/dev/null 2>&1 || true
    codesign --force --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP" >/dev/null 2>&1
else
    echo "▸ Ad-hoc signing (run ./setup-signing.sh for a persistent Music permission)…"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

# Deploy to /Applications so the copy you launch (Dock/Spotlight) is ALWAYS the
# latest build. Without this, a stale copy in /Applications silently shadows
# every rebuild. ditto preserves the code signature.
#
# Deploy is OPT-IN in this (efficiency-tuned) copy: the original script replaced
# /Applications/Tempo.app — killing the running app — on EVERY `./build.sh`.
# Default is a local-only build; run `DEPLOY=1 ./build.sh` to push it to
# /Applications exactly like before.
if [ "${DEPLOY:-0}" = "1" ]; then
    echo "▸ Deploying to /Applications…"
    pkill -x Tempo 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Tempo.app
    ditto "$APP" /Applications/Tempo.app

    # Remove the local build bundle so it isn't a SECOND "Tempo" that Launchpad
    # and Spotlight index alongside the deployed /Applications copy.
    rm -rf "$APP"

    echo "✓ Built and deployed to /Applications/Tempo.app"
    echo "  Launch it from Spotlight/Dock as usual — it is now the current build."
else
    echo "✓ Built locally: $PWD/$APP"
    echo "  (Run with DEPLOY=1 to replace /Applications/Tempo.app as before.)"
fi
