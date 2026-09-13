# Spike findings — MicroHs as a LiveCodes `haskell-wasm` engine

**Status: spike complete.** The REPL-driven integration works end-to-end in a real
browser. Two of my initial conclusions were wrong and are corrected below; the
corrections matter more than the original plan.

Pinned artifacts: MicroHs commit `455782164e75998b140d869c1b7cdde0c8a21508`
(`web-mhs/`, mirrored at https://microhs.org/web-mhs/).

| Artifact | Bytes | sha256 (vendored = upstream, unmodified) |
| --- | --- | --- |
| `mhs-embed.js` | 95,273 | `B8E57DCAD9D060F7B4A80654008C08EF1ED4FEF9CB5C95BC6201FEECC2319770` |
| `mhs-embed.wasm` | 1,875,521 | `89131E819C615F96A964A78958A6BB5C3A9D42B6C95CDF306F143231C0270919` |

This file is the **spike log** — what was tried, what worked, and what was wrong. For the build
and package-update runbook see [BUILD.md](BUILD.md); for what can be imported see
[PACKAGES.md](PACKAGES.md); [README.md](README.md) is the entry point.

## Corrections to the first pass (important)

1. **Do NOT patch `noExitRuntime`.** I first changed `var noExitRuntime=true;` to
   `false` to expose exit codes. That breaks the REPL entirely: with it false,
   emscripten's `maybeExit()` actually exits after the first JS trampoline, so the
   REPL dies right after printing its banner — in Node *and* in Chrome. Every early
   "the REPL exits immediately" observation was this patch. The file is now
   byte-identical to upstream.
2. **`-r` / `-e` really are inert** (this one was not caused by the patch). With the
   pristine file, `-r`, `-e`, `-fno-code`, `-L` and compile-only all print nothing and
   exit 0, even with a syntax-error source. Reason (`src/MicroHs/Translate.hs`):

   ```haskell
   translateWithMap _ _ | not compiledWithMhs =
     mhsError "Not compiled with mhs, so cannot run code"
   ```

   The published bundle is a REPL-only playground. **`-r`/`-e` must not be relied on.**

## Verified working (Chrome, main-thread engine)

| Scenario | Result |
| --- | --- |
| run `main` (`putStrLn` + `print`) | `hello from MicroHs` / `55`, `exitCode 0` |
| eval expression (`map (+1) [1..5]`) | `[2,3,4,5,6]`, `exitCode 0` |
| changed source re-run | picks up new code (after `:reload`) |
| partial function (`head []`) | error: `*** Exception: error: "./Data/List.hs",389:11: head: empty list` |
| canvhs graphics | **draws** (`display $ Color red $ SolidCircle 50` → red circle on canvas) |
| boot cost | ~2.4–4.5 s including load |

## The protocol that works

The REPL is the only execution path. Drive it exactly like `web-mhs` drives its terminal:

1. Configure the Emscripten module **before the script loads**:

   ```js
   Module = {
     arguments: [],                       // no module args => interactive REPL
     locateFile: (p) => 'mhs/' + p,
     preRun: [() => {
       FS.mkdirTree('/home/web_user'); FS.chdir('/home/web_user');
       FS.writeFile('.mhsi_rc', ':set prompt=<<<LC_PROMPT>>>\n');  // sentinel prompt
       FS.writeFile('Main.hs', '');       // rewritten per run
     }],
     // initRuntime() calls FS.init() with no args and picks these up.
     stdin: () => null,                   // input never uses fd 0
     stdout: (c) => (raw += String.fromCharCode(c)),
     stderr: (c) => (raw += String.fromCharCode(c)),
     print: (t) => (raw += t + '\n'),
   };
   ```

2. Input is delivered with **`Module._set_input_char(byte)`**, one char at a time,
   yielding to the event loop between chars (`setTimeout(0)`). `Module.stdin` (fd 0)
   and `_set_input_char` before the first read are both ignored; characters only take
   effect once the REPL is waiting.
3. Completion is detected by counting the sentinel prompt in the captured output.
4. Run sequence: `import Main` → **`:reload`** → `:main`.
   `:reload` is required: the REPL caches compiled modules, so re-importing a changed
   `Main.hs` silently reuses the old code (verified: a changed program kept producing
   the previous output until `:reload` was added).
5. The REPL echoes typed input, so echoed command lines must be stripped from output.

Useful REPL commands (from `:help`): `:reload`, `:clear`, `:delete`, `:type`, `:kind`,
`:main ARGS`, `:defs`, `:save`, `:edit`, `:find`, `:set`.

## Limitations verified

| Limitation | Evidence / consequence |
| --- | --- |
| **Worker context is unreliable** | `RangeError: Maximum call stack size exceeded` inside `mhs-embed.wasm` (`wasm-function[74]` recursing), caught via worker `unhandledrejection`. 1 success, 3+ failures with identical code. Worker runs on a smaller JS stack than the main thread, which this wasm build needs. |
| **No interrupt / timeout on the main thread** | An infinite `main` blocks the tab; there is no way to interrupt a running emscripten instance. The worker would have provided this, but is not viable. |
| **stdin not supported natively** | Verified three ways (fd-0 callback, chars pre-queued, chars during the run): the program's `getLine`/`getContents` always see EOF — the REPL's input queue is separate from the program's stdin. Replaced by a pure shim (`lcInput`/`lcInputLines`/`lcInputWords`), implemented and verified. |
| **Module caching** | Mitigated by `:reload`, but the REPL remains a stateful, accumulating session. |
| **Not GHC** | MicroHs is an extended Haskell 2010 implementation at ~GHCi speed with its own error messages (`"Data/List.hs",389:11`). Many extensions *do* work (GADTs, RankNTypes, TypeApplications, OverloadedStrings, record dot); `TypeFamilies`, Template Haskell and `DeriveGeneric` do not. The common ecosystem packages (`containers`, `mtl`, `array`) are loaded at runtime; others are not packaged yet. |
| Browser coverage | Only Chrome was available here; Safari/Firefox/mobile unverified. `web-mhs` has known Safari quirks. |

## Capability profile (what a user actually gets)

Measured against the shipped bundle (base + canvhs embedded). Sources: the
[MicroHs Wiki "Language" page](https://github.com/augustss/MicroHs/wiki/Language),
`lib/base.cabal`, and the probes in `scripts/feature-probe.js` / `--probe-imports`.

### Language features — 21/26 verified

| Works | Fails |
| --- | --- |
| ADTs + `deriving (Show, Eq, Ord, Enum, Bounded)`, typeclasses + instances | **`TypeFamilies`** (type/data families) |
| higher-kinded types, `Functor`/`Foldable`/`Traversable` | **Template Haskell / QuasiQuotes** |
| **GADTs**, **RankNTypes**, **TypeApplications** | **`DeriveGeneric`** (`undefined type: Generic`) |
| `OverloadedStrings` (+`Data.Text`), `PatternSynonyms`, `LambdaCase` | **`ApplicativeDo`** (do is Monad-only: `Cannot satisfy constraint: Monad Pair`) |
| `MultiWayIf`, `MultiParamTypeClasses` + `FunctionalDependencies` | `Arrows`/`proc`, `ImplicitParams`, `RebindableSyntax`, unboxed tuples |
| `ExistentialQuantification`, `DeriveFunctor`, `GeneralisedNewtypeDeriving`, `StandaloneDeriving` | |
| record dot syntax + nested record update, list comprehensions, laziness, `case`/guards/`where` | |
| `Control.Monad.ST` + `STRef`, STM, `Control.Concurrent`, `Control.Exception`, `DeepSeq` | |

Wiki-noted differences from Haskell 2010: extensions are **always on** except `CPP`;
kind variables need an explicit `forall`; no datatype contexts; `BangPatterns` only
effective at a top-level `let`/`where`; Text I/O is always UTF-8; and **many things
that should be errors are not reported**.

`TypeFamilies`, Template Haskell and `DeriveGeneric` are the notable modern-GHC
omissions; everything a typical introductory-to-intermediate course needs is present.

### Library modules — the tutorial staples are available

For the full picture — every GHC boot library and its status, what is worth adding next, and what
can never work — see **[PACKAGES.md](PACKAGES.md)**. In short:

`Data.Map`/`Data.Set`/`Data.Sequence`, `Control.Monad.State`, `Data.Array`, `System.Random`,
`Data.Time`, `Text.Parsec`, `Text.PrettyPrint`, `Test.HUnit` and `Test.QuickCheck` are all
shipped (see "Bundle additions"), so the tutorial-staple gaps are closed. An earlier import
probe of the 97 modules a course would touch scored 93/97; the three since added (parsec, pretty,
xhtml) came from that missing set, so the practical gap is now `megaparsec`, `vector`, `lens`
and `aeson`.

Present: `Prelude`, `Data.List/Maybe/Char/Either/Tuple`, **`Data.Text` (+Lazy, IO,
Encoding)**, **`Data.ByteString` (+Char8, Lazy, Short, Builder)**, `Data.Ratio`,
`Data.Complex`, `Data.Bits`, `Data.Ix`, `Data.Foldable/Traversable`, `Data.List.NonEmpty`,
`Data.Hashable`, `Data.STRef`, `Data.IORef`, `Data.Typeable`, `Data.Data`, `Data.Dynamic`,
`Data.Coerce`, `Data.Bifunctor`, `Data.String.Interpolate`, `GHC.Generics`,
`Control.Monad.ST`, `Control.Applicative/Arrow/Category/Exception/DeepSeq/Monad.Fix`,
`Control.Concurrent(+STM)`, `System.IO/Environment/Exit/Directory/Process/Cmd/Info/Mem/Timeout/CPUTime`,
`Text.Printf`, `Text.Read`, `Text.ParserCombinators.ReadP`, `Numeric`, `Data.Version`,
`Debug.Trace`, `Foreign*`, `Unsafe.Coerce`, `Graphics.CanvHs`.

Originally missing, now **shipped as runtime packages** (verified importable):
**`containers`** (`Data.Map`, `Data.Set`, `Data.Sequence`, `Data.IntMap`, `Data.IntSet`,
`Data.Tree`, `Data.Graph`), **`mtl`** (`Control.Monad.State/Reader/Writer/Except/RWS`) via
`transformers`, **`array`** (`Data.Array`, `Data.Array.ST`, `Data.Array.IO`), **`random`**
(`System.Random`), **`time`** (`Data.Time`), **`HUnit`** and **`QuickCheck`** — plus the
`ghc-compat` shim and small dependencies (`call-stack`, `splitmix`, `unordered-containers`,
`async`, `ansi-terminal`, `colour`, `haskell-lexer`, `os-string`, `exceptions`, `filepath`).

Then **parsec**, **pretty** and **xhtml** closed the GHC boot-library gap that users would
notice: `Text.Parsec` (+`Text.ParserCombinators.Parsec`, and the `Text.Parsec.String`
convenience module), `Text.PrettyPrint` (+`HughesPJ`), `Text.XHtml` (needs `semigroups`).
Verified in Chrome with real programs — a parser (`parse number "" "12345"` → `24690`),
`render (text "hello" <+> int 42 <+> parens (char 'x'))` → `hello 42 (x)`, and
`showHtml (paragraph << "hi" +++ ulist << […])` → the XHTML document string.

**`binary` is built but deliberately *not* shipped.** It compiles, and `Data.Binary.Put`
works (`runPut (putWord16be 258)` is 2 bytes), but **`Data.Binary.Get` / `decode` loops
forever** — `runGet getWord16be (BL.pack [1,2])` never returns. Since a hang freezes the result
iframe with no way to interrupt (see "Limitations"), an accurate "not available" is strictly
better than a landmine, so `import Data.Binary` now reports *why* it is withheld. Revisit if the
worker engine (which can kill a runaway) becomes reliable.

Still missing (verified "Module not found"): `Text.Megaparsec`; `Data.Vector`, `Control.Lens`,
`Data.Aeson`.

`megaparsec`, `vector` and `aeson` are **not** in MicroHs's known-to-compile list
(`Makefile.packages`: *"These are the ones I know compile"*), so they are unverified rather than
merely unpackaged — and `aeson` leans on Template Haskell/generics, which MicroHs does not
support. An earlier revision of this file wrongly said `vector`/`aeson` would build. The same
list covers plenty of non-boot libraries (tagsoup, optparse-applicative, comonad, data-default,
parser-combinators, prettyprinter, heaps, fingertree, fgl, these, assoc, …), so useful breadth
comes from there rather than from GHC's boot set.

Also from the wiki's compliance table, even "present" modules are incomplete in places:
`System.IO` lacks `hSeek`/`hTell`/`hIsEOF`/`hPrint`/`HandlePosn`/`SeekMode`;
`Data.Char` lacks `lexLitChar`/`readLitChar`; `Prelude` lacks `catch`; `Foreign.C.String`
and `Foreign.C.Types` are partial.

### Would a learner miss much?

Mostly no, with three real caveats:

1. **Diagnostics.** Errors are terse and some parse failures carry an *empty* message
   (`"./Main.hs": line 2, col 13:` for `type family …`). Positional errors are decent
   (`line 5, col 8: undefined value: T.putStrLn`, `Cannot satisfy constraint: IO ~ Maybe`,
   `Module not found: Data.Map`), but there is no GHC-quality type-error explanation.
   The FAQ's answer — *"Why are the error messages so bad? Error messages are boring."* —
   is a design stance. For someone learning types, this is the biggest drawback.
2. **Testing works, with one caveat:** `HUnit`, `QuickCheck` and `hspec` all run. QuickCheck's
   default 100 tests trap the wasm at ~74, so tests need `maxSuccess`/`withMaxSuccess` lowered;
   hspec's `property` examples inherit that.
3. **Weak safety net:** things that should be errors often are not, so a learner gets
   less feedback than GHC would give.

Beyond that, the language surface is genuinely strong — GADTs, RankNTypes,
TypeApplications, OverloadedStrings and record dot all work, so even an advanced reader
("Thinking with Types"-style material) is mostly served.

### Competitive programming?

Effectively out of scope:

- **Input needs the shim.** `getLine`/`getContents` cannot work (see limitations), but the
  `lcInput`/`lcInputLines`/`lcInputWords` bindings make input-driven exercises possible, so
  this is an API difference to document rather than a blocker.
- **Speed.** Execution is a combinator interpreter, ~GHCi class — orders of magnitude
  slower than compiled GHC. CP solutions are written for compiled speed.
- **Data structures are now available** — `Data.Map`/`Set`/`Sequence`/`Array` ship with the
  bundle — so the remaining blocker is speed, not tooling: an interpreter cannot meet CP
  time limits.
- No fast-IO idioms (`ByteString` exists, but not wired to stdin), no seeking.

### Sharing snippets / playground use

- Sharing itself is unaffected — LiveCodes already handles URLs, gists, snippets, embeds;
  the viewer just pays one ~1.9 MB download and a ~2.4–4.5 s boot.
- **Portability is the catch in both directions:** extensions are always on and the
  library set differs, so a snippet written here may not compile in GHC (and vice versa).
  Anything restricted to the shared core (Prelude, `Data.List/Maybe/Text/ByteString`,
  typeclasses, ADTs, folds) travels fine.
- Interactive snippets work only through the input shim (`lcInput`/`lcInputLines`/`lcInputWords`),
  not `getLine`; snippet authors need to know the difference.
- Randomness and dates are unavailable (`System.Random`, `Data.Time`), so clock/RNG-based
  demos won't run; `System.CPUTime` exists but not `Data.Time`.



## Bundle additions (implemented)

### 1. Runtime package loading — lazy, on demand

Adding packages does **not** require rebuilding the wasm (which would need Emscripten). The
bundle embeds `base` + `canvhs`; other packages are MicroHs packages loaded at runtime:

- package files are written into the virtual FS and `-a/pkgs` adds that directory to the
  compiler's search path (`-aPATH` *appends* to the package path);
- DB layout (from `src/MicroHs/Package.hs`): `packages/<name>.pkg`, plus a `<Module>.txt`
  map per exported module containing the package file name.

Everything is driven by a manifest, `public/pkgs/index.json`:

```json
{ "modules":     { "Data.Map": "containers-0.8.pkg", ... },
  "packages":    { "containers-0.8.pkg": ["array-mhs-0.5.8.0.pkg"], ... },
  "embedded":    ["Data.List", "Data.Text", ...],
  "unavailable": [ { "prefix": "Data.Aeson", "reason": "not bundled with this playground" } ] }
```

`embedded` lists what the wasm already provides (`base`, 196 modules), and `unavailable` is the
curated set of modules users expect but that cannot be provided here. `embedded` is derived from
the build (maps whose target is `base-*.pkg`); `unavailable` lives in
`scripts/module-support.json` and is merged in by the generator. Together they are what makes an
accurate *"not available here, because X"* possible — see §5.

`public/packages.js` resolves the program's `import` lines to packages and closes over
`packages` dependencies; only those `.pkg` files are fetched, and the `<Module>.txt` maps are
**synthesised from the manifest** rather than shipped as one tiny file per module. A legacy flat
file list is still understood (and simply disables lazy loading).

Because the package path is fixed at boot, a program needing a package that is not loaded
causes a reload: the runner returns `{reload: true, needsPackages: […]}` with nothing executed,
the page persists the source plus the enlarged package set and reloads, and boots straight
into the run. The set is a **monotonic union**, so alternating between programs does not
thrash. The worker engine instead discards and respawns the worker, which boots with the new
set (no page reload) — its package plumbing works, though the worker engine itself is still
unreliable for the reason noted above.

**Verified in Chrome** (fresh `localStorage` each time):

| program | packages loaded |
| --- | --- |
| `print (sum [1..10])` | **0** — nothing fetched |
| `import qualified Data.Map` | 2 — `containers-0.8`, `array-mhs-0.5.8.0` |
| `import Control.Monad.State` | 2 — `mtl-2.3.2`, `transformers-0.6.2.0` |
| `import Test.QuickCheck` (and use it) | 9 — QuickCheck, random-mhs, splitmix, time, mtl, transformers, containers, array-mhs, ghc-compat |

each producing the right output, and `persistedPackages()` matching `state.loaded`. A
Prelude-only run now boots in ~4.2 s against ~12.5 s when every package was preloaded. The
package directory holds only the `.pkg` files plus the manifest, rather than one `.txt` map per
module (178 files when every package was preloaded eagerly).

### 2. Usable compile diagnostics

Compile errors surface during `import Main` / `:reload`; `:main` then only says
`undefined value: main`. Capturing those steps turns a useless message into e.g.

```
*** Exception: error: "./Main.hs": line 3, col 19: Cannot satisfy constraint: IsString _a3
```

Implemented in both runners (browser + Node), de-duplicated because both steps can report
the same diagnostic. Verified in Chrome and headlessly.

### 3. Input shim

Native stdin is unusable, so the harness appends pure bindings to the user's module:

```haskell
lcInput      :: String     -- the whole input box
lcInputLines :: [String]
lcInputWords :: [String]
```

Appended at the end of the module, so it needs no imports and cannot clash with the header.
Wired to the harness's input box and verified (`1 2 3 4 5` → `15`).

### 4. Readable program output

Output arrives as UTF-8 bytes one char code at a time, and libraries like hspec drive the
terminal. The runner now decodes through a streaming `TextDecoder` (so `✔` is not mangled into
`￢ﾜﾔ`), strips ANSI/VT escape sequences and BEL, honours backspaces, and collapses
carriage-return overwrites so a progress line keeps only its final state. hspec renders as:

```
arithmetic
  adds [✔]
  subtracts [✔]

Finished in 2.0000 seconds
2 examples, 0 failures
```

### 5. Accurate "not available" messages

A bare `Module not found: Data.Aeson` reads like a broken package, when it is really a documented
limit of the playground. Every imported module is now classified:

| kind | meaning |
| --- | --- |
| `package` | provided by a shipped `.pkg` — loaded lazily, as before |
| `embedded` | provided by `base` inside the wasm — always present |
| `unavailable` | cannot be provided here; carries a reason |
| `unknown` | nothing known about it |

`unavailable` matches by dot-boundary prefix and is checked **after** `package`/`embedded`, so a
broad rule (`GHC`, `Language.Haskell.TH`) does not shadow what `ghc-compat` really does provide
(`GHC.Stack`, `Language.Haskell.TH.Syntax`, `Language.Haskell.TH.Quote`).

The check runs on the `import` lines **before anything is compiled**, so an unsatisfiable program
is answered immediately — no boot, no compile — in both engines:

```
Not available in this playground:
  Language.Haskell.TH — Template Haskell is not supported by MicroHs (only its types, via ghc-compat)
  GHC.Prim — GHC internal modules are not exposed by MicroHs
  System.Posix.Process — POSIX-only modules are not available in the browser

This playground provides base (196 modules) plus 29 packages (281 modules), including
Data.Map, Control.Monad.State, System.Random, Data.Time, Test.Hspec, Test.QuickCheck, ….
```

A backstop also annotates any `Module not found: X` that still reaches the compiler (a line typed
straight into the REPL, or a module reached indirectly). Imports inside comments are stripped
first, so a commented-out `import Data.Aeson` is not reported as missing. The curated rules live
in `scripts/module-support.json` (merged into the manifest by the generator); the counts quoted
in the message come from the manifest, so they cannot drift.

Covered by `node scripts/test-manifest.js` — 37 checks (classification, prefix precedence,
comment handling, reasons, message shape, and the parsec/pretty/xhtml closures). Verified in
Chrome on the main-thread engine and the worker engine, plus the lazy-load/reload path from a
cold `localStorage`.

### Building the package files — done

Generating packages needs MicroHs to compile them. Two dead ends first:

1. `cabal build` produces a working `mhs` (GHC flavour) — **but it cannot write packages**:
   `System.IO.Serialize` is stubbed with *"serialization not available with ghc"*.
2. The **self-hosted** compiler must be built from the shipped `generated/mhs.c`. That builds
   on Windows/mingw with three fixes (the `mingw` runtime config, `-DINLINE=inline`, and
   `setenv`/`unsetenv` shims with prototypes force-included, since gcc >= 14 rejects implicit
   declarations) — but the result **segfaults (`0xC0000005`) compiling `base`**. The `mingw`
   runtime config is not the supported Windows path (`Makefile.windows` targets MSVC).

It worked immediately on Linux, in a container — no GHC needed, only a C compiler:

```
docker run --rm -v <repo>/scripts:/scripts:ro -v <repo>/.build/pkgs:/out \
  -v <repo>/.build/work:/build -v <repo>/.build/db:/db ubuntu:24.04 \
  bash -c "apt-get update -qq && apt-get install -y -qq build-essential git curl ca-certificates >/dev/null \
           && cp /scripts/build-packages-linux.sh /tmp/b.sh && WORK=/build OUT=/out DB=/db bash /tmp/b.sh"
```

Mounting `/db` (and `/build`, which keeps the cloned sources and the already-built `bin/mhs`)
makes re-runs incremental — only missing packages are built. To add packages without redoing the
set, override `PACKAGES`, e.g. `PACKAGES='fgl'`; the default is the full canonical list.
`PACKAGES` is also how `binary` is rebuilt if it is ever re-evaluated — it is deliberately absent
from the default (it is withheld, and mcabal rebuilt it on every run because its snapshot version
and its `.cabal` version disagree).

`scripts/build-packages-linux.sh` does the whole chain: clone MicroHs at the pinned commit →
build the self-hosted `mhs` → build `mcabal` → build `cpphs` → install `base` → install
`array transformers mtl containers random time unordered-containers async HUnit QuickCheck hspec
parsec semigroups pretty xhtml` (each with `-r` for dependencies) → emit the DB. `base` is
installed first and kept between runs, so re-runs only build what is missing.
Gotchas encoded in the script: `-P<name>` and `-L<name>` must be **joined** to their value
(a bare `-L` silently lists every installed package, which is how the first dependency dump
came out empty); flags must precede the `install` command and mcabal takes one package at a
time; `curl` must be present (mcabal shells out to it for the Stackage snapshot);
`packageDbPath` in the generated `mhs.conf` must point at the DB, otherwise dependency packages
fail with *"Module not found: Prelude"*; `call-stack` needs
`--options=-D__GLASGOW_HASKELL__=990` for hspec's benefit (see below); and three packages come
from git rather than Hackage, mirroring MicroHs's own `Makefile.packages` — QuickCheck
(2.16.0.0 hits a kind error), and `pretty`/`binary`.

Produced (MicroHs 0.16.6.0, combinator file v8.4 — matching the bundle exactly):

**29 packages ship** (`public/pkgs/packages/`), totalling 8.0 MB, plus the `index.json`
manifest — 30 files. Nothing is fetched until a program imports something from them (see the
lazy-loading section above). Grouped by purpose:

| group | packages |
| --- | --- |
| containers / data | `containers-0.8`, `array-mhs-0.5.8.0`, `unordered-containers-0.2.21` |
| effects | `transformers-0.6.2.0`, `mtl-2.3.2`, `exceptions-0.10.11` |
| parsers / printers | `parsec-3.1.18.0`, `pretty-1.1.3.6`, `xhtml-3000.2.2.1`, `semigroups-0.20.1` |
| random / time | `random-mhs-1.3.2.2`, `splitmix-0.1.3.2`, `time-1.15` |
| testing | `hspec-2.11.17`, `hspec-core-2.11.17`, `hspec-expectations-0.8.4`, `hspec-discover-2.11.17`, `QuickCheck-2.18.0.0`, `quickcheck-io-0.2.0`, `HUnit-1.6.2.0`, `call-stack-0.4.0` |
| concurrency | `async-2.2.6` |
| deps pulled in | `ansi-terminal-1.1.5`, `ansi-terminal-types-1.1.3`, `colour-2.3.7`, `filepath-1.5.5.0`, `os-string-2.0.10`, `haskell-lexer-1.2.1`, `ghc-compat-0.5.11.0` |
| built but **not shipped** | `binary-0.8.9.2` — compiles, but `Data.Binary.Get` hangs; also dropped from the build's default `PACKAGES`, since mcabal rebuilt it on every run |
| — | `base-0.16.6.0` — **not shipped**; base is embedded in the wasm |

Adding a package is three steps: build it, copy the `.pkg` into `public/pkgs/packages/`, re-run
`node scripts/build-manifest.js`. Shipping is decided purely by which `.pkg` files are present —
which is how `binary` is excluded without touching the build.

**Verified in Chrome** (each loads its package then runs):

| package | evidence |
| --- | --- |
| `random` | `randomRIO (1,6)` → printed `random 1..6 in range: True` |
| `time` | `getCurrentTime` → printed a real `UTCTime` day |
| `HUnit` | `assertEqual "addition" (2+2) 4` → `HUnit assertion passed` |
| `QuickCheck` | `quickCheckWith stdArgs { maxSuccess = 10 } …` → `+++ OK, passed 10 tests.` |
| `parsec` | `parse number "" "12345"` with `number = read <$> many1 digit` → `24690` |
| `pretty` | `render (text "hello" <+> int 42 <+> parens (char 'x'))` → `hello 42 (x)` |
| `xhtml` | `showHtml (paragraph << "hi" +++ ulist << [li << "one", li << "two"])` → full XHTML document |

Two caveats found here:

- **QuickCheck needs `maxSuccess` lowered.** The default (100 tests) **traps the wasm**
  (`Aborted(RuntimeError: unreachable)`) after ~74 tests; with `maxSuccess = 10` it passes
  cleanly. Reasonable interpretation: a stack/heap limit in the interpreter under the test
  loop, consistent with the worker stack-overflow finding above. 2.16.0.0 from Hackage would
  not compile at all (`Test/QuickCheck/Exception.hs:59: kind error: cannot unify Type and
  _a6 -> _a7`), so the build mirrors MicroHs's `Makefile.packages` and takes QuickCheck from
  `git://github.com/nick8325/quickcheck.git` (2.18.0.0).
- **`hspec` works** (once `async` is installed — see the note above). The `HasCallStack` failure
  was *not* a missing stub: `call-stack`'s `Data.CallStack` guards that export behind
  `#if __GLASGOW_HASKELL__ >= 704`, which CPP does not define under MicroHs, so the module
  compiled **without exporting it**. Rebuilding just that package with
  `--options=-D__GLASGOW_HASKELL__=990` restores the GHC code path (`ghc-compat` already
  provides `GHC.Stack.HasCallStack`), and `hspec-expectations` + `quickcheck-io` build.
  `hspec-core` then needs `Control.Concurrent.Async`, i.e. the `async` package, which in turn
  needs `unordered-containers` — both are in the build list now.

  Verified in Chrome:

  ```
  arithmetic
    adds [✔]
    subtracts [✔]

  Finished in 2.0000 seconds
  2 examples, 0 failures
  ```

  Caveat: hspec's `it … $ property …` inherits QuickCheck's default 100 tests and therefore
  hits the same wasm trap; use `withMaxSuccess n` there too.

- **Two more gotchas found while wiring hspec up.** (1) `curl` must exist in the image: mcabal
  shells out to it for every tarball, and a missing curl surfaces misleadingly as
  *"no PKG.cabal file"* with an empty package directory. (2) `async` is not pulled in by
  hspec's `-r` recursion reliably, so `unordered-containers` and `async` are now listed
  explicitly before `hspec`.

- **`binary` compiles but its reader hangs.** Building it succeeds and `Data.Binary.Put` is
  fine — `BL.length (runPut (putWord16be 258))` is `2` — but `Data.Binary.Get` never returns:
  `runGet getWord16be (BL.pack [1,2])` and `runGet getWord16be (runPut (putWord16be 258))` both
  hang, so `:main` times out and the REPL stays stuck until the page is reloaded. Since a hang
  is the worst possible failure here (no interrupt), the package is **built but not shipped**,
  and `import Data.Binary` reports the reason instead. `Put`-only uses will work if this is ever
  revisited — most usefully once the worker engine can reliably kill a runaway.

- **One boot timeout seen.** On a cold `localStorage` the very first `boot()` occasionally
  exceeded its 20 s "first prompt" wait and the run failed with `Timed out waiting for first
  prompt`; reloading and running again was fine, and every subsequent run booted in a few
  seconds. If it recurs, the timeout (not the bundle) is the thing to raise.

Boot cost no longer scales with the package set: nothing is fetched until a program imports
something that lives in a package, and then only that package plus its MicroHs dependencies.
A Prelude-only run fetches nothing and boots in ~4.2 s (against ~12.5 s when everything was
preloaded eagerly). See "Runtime package loading — lazy, on demand" above.

**Verified in Chrome** — the runtime reports `Loading package /pkgs/packages/containers-0.8.pkg`,
and a program using several package families runs correctly:

```haskell
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Array
import Control.Monad.State
-- [(1,100),(2,200)]  [1,2,3]  [10,20,30]  [0,1,2]
```

A probe of the 15 previously-missing modules (`Data.Sequence`, `Data.IntMap`,
`Data.Map.Strict/Lazy`, `Control.Monad.Reader/Writer/Except/RWS`, `Control.Monad.Trans.State`,
`Data.Array.ST/IO`, `Data.Tree`, `Data.Graph`, `Data.IntSet`, `Data.Functor.Identity`) now
reports **OK** for all of them. Adding a package is therefore: build its `.pkg`, drop it in
`public/pkgs/packages/`, and regenerate `index.json` with `node scripts/build-manifest.js` — the
wasm is untouched and nothing else needs changing. The full runbook is in
[BUILD.md](BUILD.md).

#### Provenance — real packages vs MicroHs forks

Not everything shipped is literally upstream, and the split is worth knowing:

- **Real upstream Hackage packages, unmodified source:** `containers-0.8` (maintainer
  `libraries@haskell.org`, home `github.com/haskell/containers`, BSD-3), `transformers-0.6.2.0`,
  `mtl-2.3.2`. MicroCabal downloads
  `https://hackage.haskell.org/package/<name>-<ver>.tar.gz` (`hackageSrcURL` in
  `MicroCabal/Main.hs`) and compiles them; it patches only the **Cabal metadata**
  (`mhsPatchDepends` rewrites `build-depends`) — there is no source-patching mechanism.
- **MicroHs forks:** `array-mhs-0.5.8.0` — Hackage says verbatim *"This is a copy of the array
  package adapted for MicroHs"* (`github.com/augustss/array-mhs`); `random-mhs` likewise.
  MicroCabal hardcodes exactly these substitutions:
  `mhsPackages = [("array", array-mhs 0.5.8.0), ("random", random-mhs 1.3.2.2)]`.
  Same API, adapted source.
- **A shim, not an implementation of what it names:** `ghc-compat-0.5.11.0` supplies `GHC.*`
  and `Language.Haskell.TH.Syntax/Quote` — Template Haskell *types only*, no splicing — taken
  from GHC's base and adapted. mcabal injects it into **every** third-party package.
- **Not separate packages at all:** `bytestring`, `text`, `deepseq`, `hashable`, `directory`, …
  are modules inside MicroHs's own `base`. MicroCabal carries pretend versions
  (`base 4.19.1.0`, `bytestring 0.12.1.0`, `deepseq 1.4.4.0`, `hashable 1.0.0.0` — annotated
  *"very rudimentary"*) so the dependency solver's constraints resolve against it.

Consequences: `Data.Map`/`Set`/`Sequence`, `transformers` and `mtl` are the genuine libraries
compiled by a different compiler, so semantics should match (performance is interpreter-class);
`Data.Array` is an adapted copy; `hashable` is rudimentary, which can affect the performance —
not the correctness — of hash-based structures; and the dependency edges recorded in our `.pkg`
files differ slightly from Hackage's because of the rewriting above.



## Recommendation for LiveCodes

Because the worker is not viable, the integration should mirror how LiveCodes already
runs result-page scripts for the `*-wasm` languages, but on the **result iframe's main
thread** (like `web-mhs`), accepting the loss of a hard interrupt:

- `lang-haskell-wasm.ts`: identity `compiler.factory`, `scripts: [baseUrl + '{{hash:lang-haskell-wasm-script.js}}']`,
  `scriptType: 'text/haskell-wasm'`, `compiledCodeLanguage: 'haskell'`, `liveReload: true`,
  `largeDownload: true`.
- `lang-haskell-wasm-script.ts`: boots MicroHs on the result page with the Module config
  above, exposes `livecodes.haskell.{run, input, loaded, output, error, exitCode}`, and
  posts `{type:'loading'}` while booting.
- To satisfy the `{output, error, exitCode}` contract, reuse the protocol in
  `public/repl-runner.js` (prompt sentinel, `import Main` → `:reload` → `:main`, echo
  stripping, error classification).
- An infinite program freezes the result iframe. Recover by reloading the iframe; expose
  this via the existing full-reload escape hatch (cf. Zig's `// __livecodes_reload__`).
- Host the pinned bundle in `live-codes/browser-compilers` and reference it from
  `vendors.ts`; add MicroHs (Apache-2.0) to the licence lists.
- Document the MicroHs caveat prominently: **Haskell 2010 subset, not GHC**.

A better long-term option remains: ship a purpose-built MicroHs bundle whose
non-interactive path works (`compiledWithMhs` true), which would restore the clean
`{output, error, exitCode}` contract and avoid REPL/echo parsing. That is a
build-and-release task (GHC + Emscripten + MicroHs bootstrap), not a spike.

## Layout

```
public/index.html              harness UI (source, input, engine/mode/timeout, canvas, log)
public/repl-runner.js          main-thread REPL driver (verified in Chrome)
public/packages.js             manifest fetch + lazy package resolution (window & worker)
public/worker-runner.js        worker client with boot+run timeout (worker itself unreliable)
public/haskell-worker.js       worker-side REPL driver + diagnostics
public/canvhs-glue.js          Graphics.Canvhs JS glue (canvas, rAF, Web Audio)
public/mhs/                    pinned bundle + VERSION.md
public/pkgs/                   29 packages + index.json manifest (8.0 MB, 30 files)
scripts/build-packages-linux.sh   builds the .pkg files (Docker/Ubuntu; see above)
scripts/build-manifest.js         generates public/pkgs/index.json from a build (Node —
                                  PowerShell's ConvertTo-Json mangles arrays)
scripts/module-support.json       curated "cannot be provided here" rules (with reasons)
scripts/test-manifest.js          asserts module classification (37 checks)
scripts/dump-deps.sh              dumps package dependencies (`-L` joined!)
scripts/get-async.sh              installs unordered-containers + async + hspec
scripts/probe-stdin.js            demonstrates that program stdin is dead (EOF)
scripts/node-repl-run.js          Node REPL driver — same protocol, headlessly
scripts/node-test.js              headless suite (5/5 passing)
scripts/feature-probe.js          language-feature matrix (21/26)
scripts/node-run.js               Node probe for the batch/argv paths (documents inertness)
scripts/debug-packages.sh         one-off: how to read package metadata
scripts/build-microhs-packages.ps1  Windows/mingw attempt (MSVC needed; see above)
serve.js                       zero-dependency static server (node serve.js [port])
canvhs-proof.png               screenshot: Graphics.Canvhs drawing in Chrome
hello.hs                       sample program
PACKAGES.md                    what can and cannot be imported, and why (read this first)
```

Module inventory (embedded modules):
`node scripts/node-repl-run.js --probe-imports Prelude,Data.Map,...`.
Package-provided modules are exercised through the browser harness, which loads the DB.

Reproduce:

- package support: `node scripts/test-manifest.js` (see `PACKAGES.md`)
- headless suite: `node scripts/node-test.js`
- feature matrix: `node scripts/feature-probe.js`
- browser flow: `node serve.js`, then open http://localhost:8123/
