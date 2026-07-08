#!/bin/sh
#
# Generates ModernKey/BuildInfo.h with the REAL build date/time and git commit.
#
# Why: the About panel used __DATE__, which only refreshes when OpenKeyManager.m
# is recompiled — so incremental builds showed a stale "Ngày cập nhật" date.
# This runs on every build (the build phase is marked always-out-of-date) so the
# displayed date always matches the actual build, and the short commit hash makes
# it easy to tell exactly which build is installed.
#
# The generated header is gitignored; getBuildDate() falls back to __DATE__ if it
# is ever missing (e.g. IDE indexing before the first build).

set -eu

: "${SRCROOT:?SRCROOT must be set by Xcode}"

OUT="${SRCROOT}/ModernKey/BuildInfo.h"
BUILD_DATE="$(date "+%b %e %Y %H:%M")"
GIT_COMMIT="$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo "nogit")"

# Flag builds made with uncommitted changes so they can't be mistaken for a clean build.
if ! git -C "${SRCROOT}" diff --quiet HEAD 2>/dev/null; then
    GIT_COMMIT="${GIT_COMMIT}+"
fi

TMP="$(mktemp)"
{
    echo "// AUTO-GENERATED on every build by Scripts/generate_buildinfo.sh."
    echo "// Do not edit and do not commit (it is gitignored)."
    echo "#define OPENKEY_BUILD_DATE \"${BUILD_DATE}\""
    echo "#define OPENKEY_GIT_COMMIT \"${GIT_COMMIT}\""
} > "${TMP}"

# Only replace when the content actually changed, to avoid recompiling every build
# when nothing but... nothing changed (content is stable within the same minute).
if [ ! -f "${OUT}" ] || ! cmp -s "${TMP}" "${OUT}"; then
    mv "${TMP}" "${OUT}"
else
    rm -f "${TMP}"
fi
