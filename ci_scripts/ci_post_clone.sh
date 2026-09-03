#!/bin/sh
# Xcode Cloud runs this immediately after cloning, before dependency
# resolution and the build. This repo GENERATES its .xcodeproj from
# project.yml (XcodeGen) and gitignores the result, so CI must generate
# the project here or there is no scheme for Xcode Cloud to build.
set -eu

echo "ci_post_clone: ensuring XcodeGen is available"
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

# Xcode Cloud exports the checkout path; fall back to this script's parent.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

echo "ci_post_clone: generating Xcode project from project.yml"
xcodegen generate
echo "ci_post_clone: generated -> $(ls -d ./*.xcodeproj 2>/dev/null)"
