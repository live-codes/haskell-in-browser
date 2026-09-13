#!/usr/bin/env bash
# Dump each installed package's dependencies, for the lazy-loading manifest.
# Reuses the already-built toolchain (/build) and package DB (/db).
#
#   <pkg file>|<dep name-version> <dep name-version> ...
#
# Note: mhs joins -L to its argument, exactly like -P — a bare `-L` just lists
# every installed package.
set -uo pipefail

cd /build/MicroHs
export MHSDIR=/build/MicroHs
OUT=${OUT:-/out}

: > "$OUT/deps.txt"
for pkg in $(find /db/mhs-0.16.6.0/packages -maxdepth 1 -name '*.pkg' | sort); do
  b=$(basename "$pkg")
  d=$(./bin/mhs "-L$pkg" 2>/dev/null | sed -n 's/^depends: //p')
  echo "$b|$d" >> "$OUT/deps.txt"
done

echo "deps for $(wc -l < "$OUT/deps.txt") packages:"
cat "$OUT/deps.txt"
