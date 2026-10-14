#!/bin/bash
# SPDX-FileCopyrightText: 2026 Adeveda Enterprises Private Limited
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Double-click in Finder: pulls the latest changes, rebuilds Mixar when the
# checkout moved since the last successful build, then launches it.
# Windows counterpart: "Update and Run Mixar.bat".

set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT_DIR="$(pwd)"
# Finder-launched shells may lack Homebrew (git-lfs, cmake) on PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

fail() {
    echo
    echo "ERROR: $*"
    echo
    read -r -p "Press Return to close..." _
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git was not found. Install the Xcode Command Line Tools: xcode-select --install"

if [ ! -f .env ]; then
    cp .env.example .env || fail "could not create .env from .env.example"
    echo "Created .env from .env.example"
fi
MIXAR_ENV="$(sed -n 's/^[[:space:]]*MIXAR_ENV[[:space:]]*=[[:space:]]*//p' .env | tail -1 | tr -d "\r\"' ")"
MIXAR_ENV="${MIXAR_ENV:-Prod}"
BUILD_ENV_DIR="$ROOT_DIR/build/$MIXAR_ENV"
APP="$ROOT_DIR/build/$MIXAR_ENV/bin/Mixar.app"
# "<commit> <Blender version> <app version>" of the last successful build.
STAMP="$BUILD_ENV_DIR/.mixar-autobuild-stamp"
LOG="$ROOT_DIR/build/update-and-run-$MIXAR_ENV.log"

# The post-merge hook re-pins upstream/ after a pull (normally wired by make init).
git config core.hooksPath .githooks

echo "== Checking for updates ($(git rev-parse --abbrev-ref HEAD)) =="
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if ! git pull --ff-only; then
        echo "WARNING: could not pull updates (local changes or a diverged branch)."
        echo "         Continuing with the current checkout."
    fi
else
    echo "WARNING: this branch tracks no remote branch; skipping the pull."
fi

# In a fork, also bring in the official repository's changes and release
# tags (.github/workflows/sync-official.yml does the same on GitHub hourly).
OFFICIAL_SLUG="Mixar-AI/mixar-app"
OFFICIAL_BRANCH="main"
if ! git remote get-url origin 2>/dev/null | grep -qiE "$OFFICIAL_SLUG(\.git)?$"; then
    OFFICIAL_REMOTE="$(git remote -v | awk -v s="$OFFICIAL_SLUG" \
        'tolower($2) ~ tolower(s) "(\\.git)?$" && $3 == "(fetch)" {print $1; exit}')"
    if [ -z "$OFFICIAL_REMOTE" ]; then
        OFFICIAL_REMOTE="mixar-official"
        git remote add "$OFFICIAL_REMOTE" "https://github.com/$OFFICIAL_SLUG.git"
    fi
    echo "== Fetching official Mixar changes ($OFFICIAL_REMOTE) =="
    if ! git fetch --tags "$OFFICIAL_REMOTE" "$OFFICIAL_BRANCH"; then
        echo "WARNING: could not reach the official repository; skipping its changes."
    elif [ "$(git rev-parse --abbrev-ref HEAD)" != "$OFFICIAL_BRANCH" ]; then
        echo "Note: on a feature branch; official changes merge into $OFFICIAL_BRANCH only."
    elif git merge-base --is-ancestor "$OFFICIAL_REMOTE/$OFFICIAL_BRANCH" HEAD; then
        echo "Already includes the official $OFFICIAL_BRANCH."
    elif git merge --no-edit "$OFFICIAL_REMOTE/$OFFICIAL_BRANCH"; then
        git push origin "$OFFICIAL_BRANCH" \
            || echo "WARNING: merged locally but could not push to your fork."
    else
        git merge --abort 2>/dev/null
        echo "WARNING: official changes conflict with yours (or with uncommitted files)."
        echo "         Merge $OFFICIAL_REMOTE/$OFFICIAL_BRANCH by hand; continuing without them."
    fi
fi

if git submodule status -- upstream | grep -q '^-' \
    || [ -z "$(ls -A upstream/lib/macos_arm64 2>/dev/null)" ]; then
    echo "== First-time setup: downloading Blender sources and libraries =="
    make init || fail "make init failed"
fi

HEAD_COMMIT="$(git rev-parse HEAD)"
BLENDER_VERSION="$(sed -n 's/.*BLENDER_VERSION:-\([0-9.]*\)}.*/\1/p' scripts/unix/settings.sh | head -1)"

# VERSION is bumped by the release pipeline, not on the tagged commit, so a
# checkout of release vX.Y.Z still says the previous version and the app would
# keep offering the release it already contains. Build as the newest release
# tag in this checkout when that is ahead of VERSION (an .env MIXAR_VERSION
# still wins: settings.sh sources .env last).
APP_VERSION="$(tr -d '[:space:]' <VERSION 2>/dev/null)"
# Highest release tag reachable from HEAD; `git describe` would pick the
# nearest one, which after a merge can be the previous release.
TAG_VERSION="$(git tag --merged HEAD --sort=-v:refname --list 'v[0-9]*' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//')"
if [ -n "$TAG_VERSION" ] && [ "$(printf '%s\n%s\n' "${APP_VERSION:-0.0.0}" "$TAG_VERSION" | sort -V | tail -1)" = "$TAG_VERSION" ]; then
    APP_VERSION="$TAG_VERSION"
fi
export MIXAR_VERSION="${APP_VERSION:-0.0.0}"

WANT="$HEAD_COMMIT $BLENDER_VERSION $MIXAR_VERSION"
HAVE="$(cat "$STAMP" 2>/dev/null || true)"

if [ -d "$APP" ] && [ "$WANT" = "$HAVE" ]; then
    echo "== Mixar $MIXAR_VERSION is up to date ($MIXAR_ENV, ${HEAD_COMMIT:0:8}) =="
else
    if pgrep -f "$APP/Contents/MacOS/Mixar" >/dev/null 2>&1; then
        echo
        echo "Mixar is running. Save your work and quit it so it can be rebuilt."
        read -r -p "Press Return once Mixar is closed..." _
    fi

    TARGET=build
    # build/ cannot be reused across a Blender release change.
    HAVE_BLENDER="$(awk '{print $2}' <<<"$HAVE")"
    if [ -d "$APP" ] && [ -n "$HAVE_BLENDER" ] && [ "$HAVE_BLENDER" != "$BLENDER_VERSION" ]; then
        TARGET=clean_build
    fi

    echo "== Building Mixar $MIXAR_VERSION ($MIXAR_ENV, make $TARGET) — log: $LOG =="
    mkdir -p "$ROOT_DIR/build"
    if [ "$TARGET" = clean_build ]; then
        ./scripts/unix/build_clean.sh --yes 2>&1 | tee "$LOG"
    else
        make build 2>&1 | tee "$LOG"
    fi
    [ "${PIPESTATUS[0]}" -eq 0 ] || fail "the build failed. See $LOG"

    mkdir -p "$BUILD_ENV_DIR"
    printf '%s\n' "$WANT" >"$STAMP"
fi

[ -d "$APP" ] || fail "Mixar was not found at $APP"

echo "== Launching Mixar =="
open "$APP" || fail "could not launch $APP"
echo "Done. You can close this window."
