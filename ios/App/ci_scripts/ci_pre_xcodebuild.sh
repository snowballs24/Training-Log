#!/bin/sh
set -eu

REPOSITORY_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}"
cd "$REPOSITORY_ROOT"
printf 'SnowLog pre-Xcode working directory: %s\n' "$(pwd)"

for REQUIRED_PATH in \
  ios/App/App/public \
  ios/App/App/config.xml \
  ios/App/App/capacitor.config.json
do
  if [ ! -e "$REQUIRED_PATH" ]; then
    printf 'error: Missing generated Capacitor resource: %s/%s. Post-clone generation did not persist into the Xcode build step; inspect ios/App/ci_scripts/ci_post_clone.sh in the Xcode Cloud logs.\n' "$(pwd)" "$REQUIRED_PATH" >&2
    exit 1
  fi
  ls -ld "$REQUIRED_PATH"
done

printf 'Generated Capacitor resources from post-clone are present; no rebuild is required.\n'
