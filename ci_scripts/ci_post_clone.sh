#!/bin/sh
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"
npm ci
npm run build:web
npx cap sync ios
