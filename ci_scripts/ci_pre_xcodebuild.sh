#!/bin/sh
set -eu

REPOSITORY_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
cd "$REPOSITORY_ROOT"
printf 'SnowLog pre-Xcode working directory: %s\n' "$(pwd)"

if [ ! -d ios/App/App/public ]; then
  printf 'Generated Capacitor public directory is absent; preparing iOS web resources.\n'
  npm ci
  npm run build:web
  npx cap sync ios
else
  printf 'Generated Capacitor public directory already exists; skipping duplicate npm and Capacitor preparation.\n'
fi

for REQUIRED_PATH in \
  ios/App/App/public \
  ios/App/App/config.xml \
  ios/App/App/capacitor.config.json
do
  if [ ! -e "$REQUIRED_PATH" ]; then
    printf 'error: Missing generated Capacitor resource: %s/%s\n' "$(pwd)" "$REQUIRED_PATH" >&2
    exit 1
  fi
  ls -ld "$REQUIRED_PATH"
done
