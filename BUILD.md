# Building this playground

How to produce the three artifacts this repo ships, and how to add or update a package later
without guessing. For *what* can be imported, see [PACKAGES.md](PACKAGES.md); for the behaviour
notes and the reasons behind them, see [FINDINGS.md](FINDINGS.md).

## Artifacts

| artifact | produced by | changes when |
| --- | --- | --- |
| `public/mhs/mhs-embed.wasm` + `.js` | MicroHs's own `web-mhs` build (Emscripten) | you move the pinned commit (rare) |
| `public/pkgs/packages/*.pkg` | the Docker build, `scripts/build-packages-linux.sh` | you add or update a package |
| `public/pkgs/index.json` | `scripts/build-manifest.js` | after any change to the package set |

`public/packages.js` reads the manifest at runtime and fetches only the packages a program
imports, so **boot cost does not grow with the package set** — shipping more packages is close to
free. What ships is decided purely by which `.pkg` files exist in `public/pkgs/packages/`.

### The one rule that matters

**The wasm bundle and the packages are version-locked.** A `.pkg` is written by MicroHs's own
serializer, and that format follows the compiler version (the "combinator file" revision — v8.4
at the pinned commit). Packages built by a different MicroHs **will not deserialize** at runtime.

So both must come from the same commit: `455782164e75998b140d869c1b7cdde0c8a21508`
(`public/mhs/VERSION.md` records the hashes). If you ever move the bundle forward, you must
rebuild every package.

## Prerequisites

- **Docker** — the package build only works on Linux. This is the whole reason the build runs in
  a container.
- **Node ≥ 18** — manifest generator, tests, dev server, headless REPL suite.
- **Chrome** — for browser verification (and the `agent-browser` CLI if you want to script it).
- **Emscripten SDK + a built `mhs`** — only if you rebuild the wasm itself (see below).

## Common task: add a package

**1. Check that MicroHs can even compile it.** Look for it in MicroHs's
[`Makefile.packages`](https://github.com/augustss/MicroHs/blob/master/Makefile.packages) — that
list is annotated *"These are the ones I know compile"*. Absence is not proof it fails, but it
means you are testing, not following. `PACKAGES.md` lists the ones already ruled out and why.

**2. Build it — do not rebuild the world.** Mount the existing DB and work dir so the toolchain
and installed packages are reused, and override `PACKAGES` to just the new one:

```bash
docker run --rm -v <repo>/scripts:/scripts:ro -v <repo>/.build/pkgs:/out \
  -v <repo>/.build/work:/build -v <repo>/.build/db:/db ubuntu:24.04 \
  bash -c "apt-get update -qq && apt-get install -y -qq build-essential git curl ca-certificates >/dev/null \
           && cp /scripts/build-packages-linux.sh /tmp/b.sh \
           && PACKAGES='fgl' WORK=/build OUT=/out DB=/db bash /tmp/b.sh"
```

Note the mounts are the same three paths the script uses inside the container: `/build` (sources
and the built `mhs`/`mcabal`), `/db` (package DB), `/out` (staged output, including `deps.txt`).

**3. Ship it** — copy the new `.pkg` into `public/pkgs/packages/`. Never copy `base`; it is
embedded in the wasm:

```powershell
Get-ChildItem .build\pkgs\*.pkg | Where-Object { $_.Name -notlike 'base-*' } |
  Copy-Item -Destination public\pkgs\packages\ -Force
```

**4. Regenerate the manifest** (it reads the DB's module maps and `.build/pkgs/deps.txt`):

```bash
node scripts/build-manifest.js
```

**5. Check the classification** — add expectations for the new modules to
`scripts/test-manifest.js`, then run it. It is fast and needs no browser:

```bash
node scripts/test-manifest.js
```

**6. Run it, don't just import it.** A package that compiles can still be broken —
`binary` compiles and its `Get` never returns, which is how it ended up withheld. Exercise the
module in the harness (`node serve.js`, open http://localhost:8123/) before shipping.

**7. If it cannot work**, do not ship it — add a rule to `scripts/module-support.json` and
regenerate the manifest, so users get *"not available here, because X"* instead of a mystery.
That is exactly what `binary` does.

## Full build

Same command with the default `PACKAGES` (the whole canonical set). The script:

1. clones MicroHs at the pinned commit and MicroCabal (skipped if already in `/build`);
2. builds the **self-hosted** `mhs` from `generated/mhs.c` with `cc`, then `mcabal`, then `cpphs`
   (a GHC-built `mhs` cannot write packages — *"serialization not available with ghc"*);
3. writes `mhs.conf` with `packageDbPath` pointing at the DB;
4. installs `base` (skipped if present) and then each package in `PACKAGES` with `-r`;
5. **rebuilds `call-stack`** with `-D__GLASGOW_HASKELL__=990` (hspec needs it — see
   FINDINGS.md). Unlike the others this happens on every run, even when nothing changed
   (observed on consecutive runs); it is the one step that makes a "no-op" build slow;
6. collects every non-`base` `.pkg` and module map into `/out`, and dumps `deps.txt`.

Re-runs are incremental because `/db` persists — installed packages are skipped and the toolchain
is reused. A cold run (empty `/db`, empty `/build`) rebuilds everything and takes substantially
longer.

## Updating a package

Versions come from the **Stackage snapshot** that `mcabal update` fetches — there is no way to ask
mcabal for a specific version (`getPackageInfo` matches the package *name* exactly), so
`mcabal install QuickCheck-2.18.0.0` does not work.

- To pick up a newer version, delete the package from the DB and re-run — for example
  `.build/db/mhs-0.16.6.0/packages/containers-0.8.pkg` (and its extracted source dir under
  `.build/db/packages/`). Re-running alone will *not* upgrade it, because an installed package is
  skipped.
- Want to know whether a re-run will rebuild something? mcabal looks for
  `<name>-<snapshot version>.pkg`. **If the snapshot's version differs from the version in the
  package's own `.cabal`, it rebuilds that package on every single run** — `binary` is the local
  example (snapshot `0.8.9.3`, cabal `0.8.9.2`), which is why it was dropped from the default
  `PACKAGES`.

### Git-built packages and reproducibility

Three packages can only be built from git, because their Hackage releases do not compile under
MicroHs (`QuickCheck`, `pretty`) or are unshipped (`binary`). `--git-ref=` is passed to
`git clone --branch`, so it takes a **tag or branch — not a commit SHA** (`MicroCabal/Unix.hs`);
a SHA would be rejected. What is pinned today:

| package | pinned to | note |
| --- | --- | --- |
| `pretty` | tag `v1.1.3.6` | **verified equivalent**: the tag resolves to `c3a1469`, the exact commit the shipped `pretty-1.1.3.6.pkg` was built from |
| `binary` | tag `0.8.9.2` | not in the default `PACKAGES` — built once, withheld (see PACKAGES.md). Add it to `PACKAGES` to rebuild |
| `QuickCheck` | **nothing — tracks HEAD** | the repo tags stop at `2.9.2`, so there is no tag to pin; a rebuild may pick up different code |

`QuickCheck` is therefore the one non-reproducible input. To pin it by hand, clone at a known
commit and build the directory directly — `mcabal install` with no package name builds the
**current directory**, which is also the escape hatch whenever mcabal's own fetch is unusable
(this is how `async` was installed when its fetch was producing an empty directory):

```bash
cd /build/MicroHs && export MHSDIR=/build/MicroHs PATH="$PWD/bin:$PATH"
git clone https://github.com/nick8325/quickcheck.git "$DB/packages/QuickCheck-2.18.0.0"
git -C "$DB/packages/QuickCheck-2.18.0.0" checkout 997d6c9cb1ee80c7ca0a3c0fcf5a5919a9107ca4
cd "$DB/packages/QuickCheck-2.18.0.0" && mcabal --install="$DB" install
```

That is the commit that produced the currently shipped `QuickCheck-2.18.0.0.pkg`; note the version
comes from the repo's `.cabal` (2.18.0.0), not the snapshot (2.16.0.0).

## Rebuilding the wasm bundle

Only needed to move MicroHs forward or change what is embedded. The upstream command (from
`public/mhs/VERSION.md`, run in MicroHs's `web-mhs/` with a built `mhs` on `PATH` and `MHSDIR` set):

```
mhs -temscripten_web -z -i -i../mhs -i../src MicroHs.Main -omhs-embed.js --embed-packages base:canvhs
```

`--embed-packages base:canvhs` is why `base` and `canvhs` need no `.pkg` and why `base` must never
be shipped. **This has not been run in this repo** — we consumed the published bundle, verified
byte-identical to upstream by sha256. Expect to need the Emscripten SDK; treat the command above as
upstream's, not as a tested recipe here.

If you do rebuild it: update the hashes in `public/mhs/VERSION.md` and the table at the top of
`FINDINGS.md`, then **rebuild every package** (version lock above) and re-run the whole
verification list below. Also do not reintroduce local patches — `VERSION.md` explains why the
`noExitRuntime` edit must never come back.

## Where things live (`/.build`, mounted into the container)

| dir | container path | contents |
| --- | --- | --- |
| `.build/work` | `/build` | cloned MicroHs + MicroCabal, and the built `bin/mhs`, `bin/mcabal`, `bin/cpphs` |
| `.build/db` | `/db` | the package DB (`mhs-0.16.6.0/packages/*.pkg`), plus extracted sources under `packages/` |
| `.build/pkgs` | `/out` | staged build output: all non-`base` `.pkg`, module maps, `deps.txt` |

Everything there is **derived** — safe to delete, and it will be rebuilt (a cold build is much
slower, and `/build` must be re-cloned).

The script wipes `/out/*.pkg` at the start and repopulates it at the end, so an interrupted run
leaves `.build/pkgs` incomplete. That does not damage anything the manifest needs: the generator
takes the *shipped* set from `public/pkgs/packages/`, the module maps from `.build/db`, and only
`deps.txt` from `.build/pkgs`. It is still worth re-running the build before shipping, since a
partial `/out` means the new package never got collected.

**Note on git:** this repo has no `.gitignore`, so `.build/db` and `.build/pkgs` are **committed**
(≈1,600 files, ≈60 MB), while `.build/work` appears only as two nested-repo gitlinks. That is why
a fresh clone can do incremental builds — but it also means committed binaries and a permanently
noisy `git status`. Decide deliberately: ignoring `.build` makes the repo clean but forces every
contributor to rebuild the DB from scratch.

## Verifying

| what | command |
| --- | --- |
| package classification / manifest | `node scripts/test-manifest.js` |
| REPL protocol, headless | `node scripts/node-test.js` |
| source path + mid-session package loading | `node scripts/probe-runtime-loading.js` |
| language feature matrix | `node scripts/feature-probe.js` |
| browser flow | `node serve.js` → http://localhost:8123/ |

"Verified" in this repo means **run, not imported**: every package listed as working in
`FINDINGS.md` was exercised with a real program in Chrome. Keep that bar — it is the only reason
the `binary` problem was caught.

## Troubleshooting

| symptom | cause | fix |
| --- | --- | --- |
| `no PKG.cabal file` (with an empty package dir) | `curl` missing — mcabal shells out to it for every tarball | install `curl` in the image (`apt-get install -y curl`) |
| dependency builds die with `Module not found: Prelude` | `packageDbPath` in the generated `mhs.conf` does not point at the DB | let the script generate `mhs.conf`; keep the `/db` mount |
| `-L` (or `-P`) prints every installed package | the flag must be **joined** to its value | `-L<path>`, `-P<name>` |
| `serialization not available with ghc` | the GHC-built `mhs` cannot write packages | use the self-hosted `mhs` built from `generated/mhs.c` |
| `mcabal` ignores a second package name | it takes one package per invocation | one `mcabal install <pkg>` per package |
| a flag has no effect | flags must come **before** the command | `mcabal --install=… -r install <pkg>` |
| segfault (`0xC0000005`) compiling `base` on Windows | MinGW build of the self-hosted `mhs`; the supported Windows path is MSVC | use Docker/Linux (`scripts/build-microhs-packages.ps1` is a dead end) |
| hspec fails on missing `HasCallStack` | `call-stack`'s CPP branch is not taken under MicroHs | rebuild it with `--options=-D__GLASGOW_HASKELL__=990` (the script does) |
| a package imports but hangs | it compiles, runtime behaviour is broken (e.g. `binary`) | verify by running; if broken, withhold it and add an `unavailable` rule |
