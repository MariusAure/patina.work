#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "[build] Compiling Patina..."
swiftc -O \
    -o patina \
    src/Sanitize.swift \
    src/CredentialDetector.swift \
    src/Database.swift \
    src/Observer.swift \
    src/Analyzer.swift \
    src/Notifier.swift \
    src/License.swift \
    src/Onboarding.swift \
    src/LogViewer.swift \
    src/PatternExporter.swift \
    src/MenuBar.swift \
    src/main.swift \
    -framework AppKit \
    -framework ApplicationServices \
    -framework UserNotifications \
    -lsqlite3 \
    -swift-version 5

echo "[build] Done. Binary: $(pwd)/patina ($(du -h patina | cut -f1))"
echo "[build] Run with: ./patina"
