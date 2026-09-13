#!/usr/bin/env bash
# Install async (hspec-core needs Control.Concurrent.Async) and then hspec.
#
# Requires curl in the image: mcabal shells out to `curl` to fetch tarballs, and a
# missing curl shows up confusingly as "no PKG.cabal file" (empty package dir).
set -uo pipefail

cd /build/MicroHs
export MHSDIR=/build/MicroHs
export PATH="$PWD/bin:$PATH"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }

echo "=== 1. unordered-containers (async's dependency) ==="
mcabal --install=/db -r install unordered-containers && echo "unordered-containers: ok" || echo "unordered-containers: FAILED"

echo
echo "=== 2. async ==="
mcabal --install=/db -r install async && echo "async: ok" || echo "async: FAILED"

echo
echo "=== 3. hspec ==="
mcabal --install=/db -r install hspec && echo "hspec: ok" || echo "hspec: FAILED"

echo
echo "=== 4. packages in the DB ==="
ls /db/mhs-0.16.6.0/packages | sort
