#!/usr/bin/env bash
set -euo pipefail

command -v flutter >/dev/null 2>&1 || { echo "Flutter SDK is required. Install Flutter stable first." >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
flutter create --platforms=android --org=com.quantai --project-name=quantai_mobile --no-pub "$TMP_DIR/quantai_mobile" >/dev/null
mkdir -p "$ROOT_DIR/android/gradle"
cp "$TMP_DIR/quantai_mobile/android/gradlew" "$ROOT_DIR/android/gradlew"
cp "$TMP_DIR/quantai_mobile/android/gradlew.bat" "$ROOT_DIR/android/gradlew.bat"
cp -R "$TMP_DIR/quantai_mobile/android/gradle/wrapper" "$ROOT_DIR/android/gradle/"
chmod +x "$ROOT_DIR/android/gradlew"
echo "Android Gradle wrapper files installed. Run: cd \"$ROOT_DIR\" && flutter pub get && flutter build apk --release"
