#!/bin/sh
# Prints the app's version from project.yml, or from project.yml at a git ref: scripts/version.sh [ref].
# POSIX sh so the Linux version check can run it too.
set -eu
cd "$(dirname "$0")/.."
if [ $# -gt 0 ]; then git show "$1:project.yml"; else cat project.yml; fi |
  sed -nE 's/^ *CFBundleShortVersionString: "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p'
