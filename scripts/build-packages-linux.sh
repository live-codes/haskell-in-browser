#!/usr/bin/env bash
#
# Build MicroHs packages (.pkg) on Linux, for runtime loading in the browser bundle.
#
# The browser bundle embeds only `base` + `canvhs`; extra packages (containers, mtl,
# array, ...) can be fetched at runtime instead of rebuilding the wasm. This script
# produces the package files and the module maps that the runtime loader needs.
#
# Used in a Linux container, e.g.:
#   docker run --rm -v <ws>/scripts:/scripts:ro -v <ws>/.build/pkgs:/out ubuntu:24.04 \
#     bash -c "apt-get update -qq && apt-get install -y -qq build-essential git ca-certificates >/dev/null \
#              && cp /scripts/build-packages-linux.sh /tmp/b.sh \
#              && WORK=/build OUT=/out bash /tmp/b.sh > /out/build.log 2>&1"
#
# Why the self-hosted compiler: the GHC-built mhs cannot write packages
# ("serialization not available with ghc"). generated/mhs.c builds with a C compiler.

set -euo pipefail

COMMIT=455782164e75998b140d869c1b7cdde0c8a21508
WORK=${WORK:-/build}
OUT=${OUT:-/out}
DB=${DB:-/db}
# Packages to build. `base` is embedded in the browser bundle, so it is not shipped.
# MicroCabal substitutes a few names (array -> array-mhs, random -> random-mhs) and
# injects ghc-compat into every third-party package.
# The tail of the list closes the GHC boot-library gap users would notice:
# parsec (Text.Parsec), pretty (Text.PrettyPrint) and xhtml (Text.XHtml, needs semigroups),
# then the "worth adding next" set from PACKAGES.md: graphs, data structures beyond
# containers, HTML parsing, list/diff utilities and prettyprinter.
#
# `binary` is deliberately absent: it compiles, but Data.Binary.Get hangs (see PACKAGES.md),
# so it is not shipped — and because the Stackage snapshot calls it 0.8.9.3 while its own
# .cabal says 0.8.9.2, mcabal re-clones and rebuilds it on *every* run. Add it to PACKAGES
# (the case below pins it) if you ever want to re-evaluate it.
PACKAGES=${PACKAGES:-"array transformers mtl containers random time unordered-containers async HUnit QuickCheck hspec parsec semigroups pretty xhtml fgl fingertree heaps psqueues tagsoup edit-distance Diff data-ordlist dlist split monad-loops prettyprinter numbers parallel"}

mkdir -p "$WORK" "$OUT" "$DB"
# Clear stale artifacts, but keep an existing package DB so re-runs only build what
# is missing (mount /db to persist it between container runs).
rm -f "$OUT"/*.pkg 2>/dev/null || true

log() { echo; echo "=== $* ==="; }
cc_() { cc -w -O2 -Isrc/runtime -Isrc/runtime/unix src/runtime/main.c src/runtime/eval.c "$@" -lm; }

fetch_repo() { # url dir
  local url=$1 dir=$2
  [ -d "$dir/.git" ] || { echo "cloning $url"; git clone --depth 1 "$url" "$dir"; }
}

log "fetching sources"
fetch_repo https://github.com/augustss/MicroHs.git "$WORK/MicroHs"
git -C "$WORK/MicroHs" checkout --quiet "$COMMIT" 2>/dev/null || true
fetch_repo https://github.com/augustss/MicroCabal.git "$WORK/MicroCabal"

MHS_DIR="$WORK/MicroHs"
cd "$MHS_DIR"
# Point the package search path at the DB we install into, otherwise packages built
# as dependencies cannot find base ("Module not found: Prelude"). mcabal's install
# root varies by version, so include the likely layouts.
sed -e 's,%GMPFLAGS,,' -e 's,%GMPLIBS,,' \
    -e "s|^packageDbPath = .*|packageDbPath = \"\$MHSPKG:$DB:$DB/mhs-0.16.6.0\"|" \
    mhs.conf.in > mhs.conf
grep -n 'packageDbPath' mhs.conf
export MHSDIR="$MHS_DIR"
mkdir -p bin

log "building self-hosted mhs"
if [ ! -x bin/mhs ]; then
  cc_ generated/mhs.c -o bin/mhs
fi
./bin/mhs --version

log "building mcabal"
if [ ! -x bin/mcabal ]; then
  ./bin/mhs -z -i"$WORK/MicroCabal/src" -ilib -ogenerated/mcabal.c MicroCabal.Main
  cc_ generated/mcabal.c -o bin/mcabal
fi
export PATH="$MHS_DIR/bin:$PATH"

log "building cpphs (needed by packages that use CPP)"
if [ ! -x bin/cpphs ] && [ -f generated/cpphs.c ]; then
  cc_ generated/cpphs.c -o bin/cpphs
fi
export MHSCPPHS="$MHS_DIR/bin/cpphs"

# ------------------------------------------------------------------ base package
if [ -f "$DB/mhs-0.16.6.0/packages/base-0.16.6.0.pkg" ]; then
  log "base already installed in $DB"
else
  log "installing base into $DB"
  ( cd lib && mcabal --install="$DB" install )
fi
echo "-- where did base land? --"
find "$DB" -name 'base-*.pkg' -printf '%s  %p\n' 2>/dev/null || find "$DB" -name 'base-*.pkg' 2>/dev/null
find "$DB" -name 'base-*.pkg' -exec cp {} "$OUT/" \; 2>/dev/null || true
ls -l "$OUT" | head -5 || true

# ------------------------------------------------------- extra packages + DB
# mcabal accepts a single package per invocation (install [PKG]).
log "refreshing the package set"
mcabal update || echo "(mcabal update failed; continuing)"

# hspec support: call-stack's Data.CallStack only exports HasCallStack when
# `__GLASGOW_HASKELL__ >= 704`, which CPP does not define under mhs. Without it the
# module compiles but does not export HasCallStack, and hspec-expectations fails with
# "not exported: HasCallStack". Defining the macro for this one package restores the
# GHC code path (ghc-compat already provides GHC.Stack.HasCallStack).
log "rebuilding call-stack with __GLASGOW_HASKELL__ defined (for hspec)"
mcabal --install="$DB" -r --options=-D__GLASGOW_HASKELL__=990 install call-stack \
  || echo "call-stack rebuild failed"

for p in $PACKAGES; do
  log "installing $p"
  # mcabal takes all flags before the command, and a single package per invocation.
  # Some packages only compile from git rather than their Hackage release, mirroring
  # MicroHs's own Makefile.packages: QuickCheck 2.16.0.0 (what the Stackage snapshot
  # resolves to) hits a kind error in mhs, and pretty/binary are built from git there too.
  #
  # `--git-ref=` is passed to `git clone --branch`, so it takes a **tag or branch, not a
  # commit SHA** (see MicroCabal/Unix.hs). pretty is pinned to the tag that produced the
  # shipped .pkg (v1.1.3.6 == commit c3a1469, verified). QuickCheck has no tags past 2.9.2
  # and therefore tracks HEAD — if that ever matters, see the manual pin recipe in BUILD.md.
  gitopt=""
  case "$p" in
    QuickCheck) gitopt="--git=https://github.com/nick8325/quickcheck.git" ;;
    pretty) gitopt="--git=https://github.com/haskell/pretty.git --git-ref=v1.1.3.6" ;;
    binary) gitopt="--git=https://github.com/haskell/binary.git --git-ref=0.8.9.2" ;;
    # These three are not installable from the snapshot, mirroring Makefile.packages:
    # fgl and dlist's MicroHs support live on git (dlist on the `mhs` branch of a fork),
    # and prettyprinter is a monorepo whose library sits in a subdirectory.
    fgl) gitopt="--git=https://github.com/haskell/fgl" ;;
    dlist) gitopt="--git=https://github.com/konsumlamm/dlist.git --git-ref=mhs" ;;
    prettyprinter) gitopt="--git=https://github.com/haskell-prettyprinter/prettyprinter.git --dir=prettyprinter" ;;
  esac
  if mcabal --install="$DB" -r install $gitopt "$p"; then
    echo "ok: $p"
  else
    echo "FAILED: $p"
  fi
done

log "collecting package DB files"
# Ship only the extras (base is embedded in the bundle).
for pkg in $(find "$DB" -name '*.pkg' | sort); do
  base=$(basename "$pkg")
  case "$base" in base-*) continue ;; esac
  cp "$pkg" "$OUT/$base"
done

# Module -> package maps. Only keep entries pointing at packages we ship.
while IFS= read -r map; do
  target=$(cat "$map")
  case "$target" in base-*) continue ;; esac
  rel=${map#"$DB"/}
  mkdir -p "$OUT/$(dirname "$rel")"
  cp "$map" "$OUT/$rel"
done < <(find "$DB" -name '*.txt' -not -path '*/packages/*')

log "output"
find "$OUT" -type f | sort | while read -r f; do printf '%10s  %s\n' "$(stat -c%s "$f")" "${f#"$OUT"/}"; done

# Package -> dependencies, used by the browser to load packages lazily.
# Format: <pkg file>|<dep name-version> <dep name-version> ...
log "dumping package dependencies"
: > "$OUT/deps.txt"
for pkg in $(find "$DB/mhs-0.16.6.0/packages" -maxdepth 1 -name '*.pkg' | sort); do
  b=$(basename "$pkg")
  # -L must be joined to its argument, like -P: a bare -L lists every package.
  d=$(./bin/mhs "-L$pkg" 2>/dev/null | sed -n 's/^depends: //p')
  echo "$b|$d" >> "$OUT/deps.txt"
done
echo "deps dumped for $(wc -l < "$OUT/deps.txt") packages"
log "done"
