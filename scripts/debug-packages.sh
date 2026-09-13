#!/usr/bin/env bash
# One-off diagnostics: how to read a package's dependencies, and whether adding
# `async` unblocks hspec. Run in the build container with /build and /db mounted.
set -uo pipefail

cd /build/MicroHs
export MHSDIR=/build/MicroHs
export PATH="$PWD/bin:$PATH"

echo "=== mhs --version ==="
./bin/mhs --version

echo
echo "=== -L by full path ==="
pkg=$(find /db/mhs-0.16.6.0/packages -name 'containers-0.8.pkg' | head -1)
echo "pkg=$pkg"
./bin/mhs -L -v "$pkg" 2>&1 | head -12

echo
echo "=== -L by package name-version ==="
./bin/mhs -L containers-0.8 2>&1 | head -12

echo
echo "=== -L by bare name ==="
./bin/mhs -L containers 2>&1 | head -6

echo
echo "=== install async ==="
mcabal --install=/db -r install async && echo "async: ok" || echo "async: FAILED"

echo
echo "=== install hspec ==="
mcabal --install=/db -r install hspec && echo "hspec: ok" || echo "hspec: FAILED"

echo
echo "=== packages now in the DB ==="
ls /db/mhs-0.16.6.0/packages | sort
