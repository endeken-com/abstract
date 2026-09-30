#!/bin/sh
set -eu

if [ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH/mobile"
else
  cd "$(dirname "$0")/../.."
fi
if command -v brew >/dev/null 2>&1; then
  brew list --versions node@22 >/dev/null 2>&1 || brew install node@22
  export PATH="$(brew --prefix node@22)/bin:$PATH"
fi
node --version
npm ci
cd ios
pod install
