#!/bin/sh
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"
npm ci
npm run build:web
npx cap sync ios

test -f ios/App/App/capacitor.config.json
test -f ios/App/App/config.xml
test -f ios/App/App/public/index.html
