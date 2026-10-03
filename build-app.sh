#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR="$ROOT_DIR/dist/Simplie.app"

cd "$ROOT_DIR"
swift build -c release --product Simplie
mkdir -p "$APP_DIR/Contents/MacOS"
cp .build/release/Simplie "$APP_DIR/Contents/MacOS/Simplie"
cp Info.plist "$APP_DIR/Contents/Info.plist"
printf 'Built %s\n' "$APP_DIR"