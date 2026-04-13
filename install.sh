#!/bin/bash
# Patina installer — download, unpack, remind about permissions.
# Run with: curl -fsSL https://raw.githubusercontent.com/MariusAure/patina.work/main/install.sh | bash
set -euo pipefail

VERSION="0.1.0"
REPO="MariusAure/patina.work"
TARBALL="patina-${VERSION}-arm64.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${TARBALL}"
DEST="/Applications"

echo "[Patina] Installing v${VERSION}..."

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "[Patina] Error: This binary is arm64 only. Your Mac is ${ARCH}."
    exit 1
fi

# Download
TMPDIR=$(mktemp -d)
echo "[Patina] Downloading from GitHub..."
curl -fSL "$URL" -o "${TMPDIR}/${TARBALL}"

# Unpack
echo "[Patina] Unpacking to ${DEST}..."
tar xzf "${TMPDIR}/${TARBALL}" -C "$DEST"
rm -rf "$TMPDIR"

# Remove quarantine (unsigned app would get blocked otherwise)
xattr -rd com.apple.quarantine "${DEST}/Patina.app" 2>/dev/null || true

echo ""
echo "[Patina] Installed to ${DEST}/Patina.app"
echo ""
echo "Next steps:"
echo "  1. Open Patina:  open /Applications/Patina.app"
echo "  2. macOS will say the app is from an unidentified developer."
echo "     Go to System Settings > Privacy & Security, scroll down, click 'Open Anyway'."
echo "  3. Grant Accessibility access when prompted."
echo "     (System Settings > Privacy & Security > Accessibility > toggle Patina on)"
echo "  4. Look for the dot icon in your menu bar. That's Patina."
echo ""
echo "To see your data later:"
echo "  sqlite3 ~/Library/Application\\ Support/Patina/patina.db 'SELECT app_name, COUNT(*) c FROM observations GROUP BY app_name ORDER BY c DESC LIMIT 10;'"
