#!/bin/sh
set -eu

REPOSITORY_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}"
cd "$REPOSITORY_ROOT"
printf 'SnowLog post-clone working directory: %s\n' "$(pwd)"

NODE_MAJOR_VERSION=""
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR_VERSION="$(node -p 'process.versions.node.split(".")[0]')"
fi

if [ "$NODE_MAJOR_VERSION" != "22" ] || ! command -v npm >/dev/null 2>&1; then
  HOMEBREW_BIN=""
  for HOMEBREW_CANDIDATE in /opt/homebrew/bin/brew /usr/local/bin/brew
  do
    if [ -x "$HOMEBREW_CANDIDATE" ]; then
      HOMEBREW_BIN="$HOMEBREW_CANDIDATE"
      break
    fi
  done

  if [ -z "$HOMEBREW_BIN" ]; then
    printf 'error: Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew; cannot install Node.js 22.\n' >&2
    exit 1
  fi

  printf 'Installing Node.js 22 with %s\n' "$HOMEBREW_BIN"
  "$HOMEBREW_BIN" install node@22
  NODE_BINARY_DIRECTORY="$("$HOMEBREW_BIN" --prefix node@22)/bin"
  export PATH="$NODE_BINARY_DIRECTORY:${PATH:-}"
fi

which node
node --version
which npm
npm --version

npm ci
npm run build:web
npx cap sync ios

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
