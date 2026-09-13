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

### Library modules — 93/97 probed available

`Data.Map`/`Data.Set`/`Data.Sequence`, `Control.Monad.State`, `Data.Array`, `System.Random`,
`Data.Time`, `Test.HUnit` and `Test.QuickCheck` are now shipped (see "Bundle additions"), so
the tutorial-staple gaps are closed.

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
`ghc-compat` shim and small dependencies (`call-stack`, `splitmix`). See "Bundle additions"
below; this raised probed availability from 76/97 to **93/97**.

Still missing (verified "Module not found"): `Text.Parsec`, `Text.Megaparsec`;
`Test.Hspec`; `Data.Vector`, `Control.Lens`, `Data.Aeson`.

`parsec`, `vector` and `aeson` build with MicroHs (`Makefile.packages` lists parsec, heaps,
fingertree, fgl, …), so those are the same packaging step rather than a compiler limitation.
`hspec` is a genuine exception: it needs `HasCallStack` from `GHC.Stack`, which `ghc-compat`
does not provide (see below).

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
2. **Testing is partly covered:** `HUnit` and `QuickCheck` work (QuickCheck needs `maxSuccess`
   lowered — the default 100 traps the wasm at ~74 tests). `hspec` does not build because
   `ghc-compat` lacks `HasCallStack`.
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

### 1. Runtime package loading — `Data.Map`, `mtl`, `Data.Array`, …

Adding packages does **not** require rebuilding the wasm (which would need Emscripten). The
bundle already embeds `base` + `canvhs`; extra packages can be loaded at runtime instead:

- fetch a package DB into the virtual FS, then add it to the compiler's search path with
  `-a/pkgs` (MicroHs's `-aPATH` appends to the package path);
- DB layout (from `src/MicroHs/Package.hs`): `packages/<name>.pkg` plus one `<Module>.txt`
  per exported module containing the pkg file name (e.g. `Data/Map.txt` → `containers-0.7.pkg`).

Implemented in `public/repl-runner.js` (`loadPackages()` + `boot()`), documented in
`public/pkgs/packages/README.txt`, file list in `public/pkgs/index.json`.

**Verified:** the compiler reports

```
package path=["./../mhs-0.16.6.0","/pkgs"]
```

so the extra search path is live and consulted; `import Data.Map` still says
`Module not found` only because no `containers` package file exists yet.

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
docker run --rm -v <repo>/scripts:/scripts:ro -v <repo>/.build/pkgs:/out ubuntu:24.04 \
  bash -c "apt-get update -qq && apt-get install -y -qq build-essential git curl ca-certificates >/dev/null \
           && cp /scripts/build-packages-linux.sh /tmp/b.sh && WORK=/build OUT=/out DB=/db bash /tmp/b.sh"
```

`scripts/build-packages-linux.sh` does the whole chain: clone MicroHs at the pinned commit →
build the self-hosted `mhs` → build `mcabal` → build `cpphs` → install `base` → install
`array transformers mtl containers random time HUnit QuickCheck hspec` (each with `-r` for
dependencies) → emit the DB. The DB is kept between runs (mount `/db`), so re-runs only build
what is missing.
Gotchas encoded in the script: `-P<name>` must be joined (`-Pbase-0.16.6.0`, no space); flags
must precede the `install` command and mcabal takes one package at a time; `curl` must be
present (mcabal shells out to it for the Stackage snapshot); `packageDbPath` in the generated
`mhs.conf` must point at the DB, otherwise dependency packages fail with *"Module not found:
Prelude"*; and QuickCheck must come from git (`--git=…/nick8325/quickcheck.git`), since the
Hackage release fails to compile.

Produced (MicroHs 0.16.6.0, combinator file v8.4 — matching the bundle exactly):

| package | size | |
| --- | --- | --- |
| `containers-0.8.pkg` | 480,013 B | real upstream — `Data.Map`/`Set`/`Sequence` |
| `QuickCheck-2.18.0.0.pkg` | 497,229 B | real upstream, built from **git** (see below) |
| `random-mhs-1.3.2.2.pkg` | 340,079 B | MicroHs fork — `System.Random` |
| `time-1.15.pkg` | 305,131 B | real upstream — `Data.Time` |
| `transformers-0.6.2.0.pkg` | 279,699 B | real upstream |
| `mtl-2.3.2.pkg` | 259,214 B | real upstream — `Control.Monad.State` etc. |
| `ghc-compat-0.5.11.0.pkg` | 244,188 B | shim, injected into every package |
| `array-mhs-0.5.8.0.pkg` | 221,157 B | MicroHs fork — `Data.Array` |
| `splitmix-0.1.3.2.pkg` | 208,705 B | dependency of `random-mhs` |
| `HUnit-1.6.2.0.pkg` | 208,218 B | real upstream — `Test.HUnit` |
| `call-stack-0.4.0.pkg` | 181,099 B | dependency of `HUnit` |
| `base-0.16.6.0.pkg` | 817,973 B | **not shipped** — base is embedded in the wasm |

The 11 shipped packages plus 166 module maps total **3.08 MB**, live in `public/pkgs/`
(`packages/*.pkg` + `<Module>.txt`) and are listed in `public/pkgs/index.json` (177 entries).

**Verified in Chrome** (each loads its package then runs):

| package | evidence |
| --- | --- |
| `random` | `randomRIO (1,6)` → printed `random 1..6 in range: True` |
| `time` | `getCurrentTime` → printed a real `UTCTime` day |
| `HUnit` | `assertEqual "addition" (2+2) 4` → `HUnit assertion passed` |
| `QuickCheck` | `quickCheckWith stdArgs { maxSuccess = 10 } …` → `+++ OK, passed 10 tests.` |

Two caveats found here:

- **QuickCheck needs `maxSuccess` lowered.** The default (100 tests) **traps the wasm**
  (`Aborted(RuntimeError: unreachable)`) after ~74 tests; with `maxSuccess = 10` it passes
  cleanly. Reasonable interpretation: a stack/heap limit in the interpreter under the test
  loop, consistent with the worker stack-overflow finding above. 2.16.0.0 from Hackage would
  not compile at all (`Test/QuickCheck/Exception.hs:59: kind error: cannot unify Type and
  _a6 -> _a7`), so the build mirrors MicroHs's `Makefile.packages` and takes QuickCheck from
  `git://github.com/nick8325/quickcheck.git` (2.18.0.0).
- **`hspec` does not build.** `hspec-expectations-0.8.4` fails with
  `Test/Hspec/Expectations.hs:65: not exported: HasCallStack` — the `HasCallStack` type from
  `GHC.Stack` is not provided by `ghc-compat` (MicroHs has no implicit call-stack support).
  `HUnit` and `QuickCheck` cover the testing use case; enabling hspec would mean adding a
  stub `HasCallStack` to ghc-compat, i.e. patching a third-party shim.

Note that boot cost grows with the package set: 177 files / 3.08 MB are fetched on every
boot (≈12 s including compile for the QuickCheck run above). Loading packages on demand — the
module maps and `import` lines already give the information needed — is the obvious next step
if the set keeps growing.

**Verified in Chrome** — the harness loads the DB (`loaded 127 package file(s)`), the runtime
reports `Loading package /pkgs/packages/containers-0.8.pkg`, and a program using all three
families runs correctly:

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
reports **OK** for all of them. Adding a package is therefore: build its `.pkg`, drop it and
its module maps in `public/pkgs/`, and add them to `index.json` — the wasm is untouched.

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
public/index.html            harness UI (source, input, engine/mode/timeout, canvas, log)
public/repl-runner.js        main-thread REPL driver (verified in Chrome)
public/worker-runner.js      worker client with boot+run timeout (worker itself unreliable)
public/haskell-worker.js     worker-side REPL driver + diagnostics
public/canvhs-glue.js        Graphics.CanvHs JS glue (canvas, rAF, Web Audio)
public/mhs/                  pinned bundle + VERSION.md
public/pkgs/                  runtime package DB (3.08 MB, 177 files): packages/*.pkg
                               + <Module>.txt maps for containers, QuickCheck, random,
                               time, transformers, mtl, ghc-compat, array, splitmix,
                               HUnit, call-stack
scripts/build-packages-linux.sh   builds those .pkg files (Docker/Ubuntu; see above)
scripts/node-repl-run.js     Node REPL driver — reproduces the browser protocol headlessly
scripts/node-test.js         headless suite (5/5 passing)
scripts/feature-probe.js     language-feature matrix (21/26) — `node scripts/feature-probe.js`
scripts/probe-stdin.js       demonstrates that program stdin is dead (EOF)
scripts/node-run.js          Node probe for the batch/argv paths (documents inertness)
scripts/build-microhs-packages.ps1  Windows/mingw attempt (MSVC needed; see above)
serve.js                     zero-dependency static server (node serve.js [port])
canvhs-proof.png             screenshot: Graphics.CanvHs drawing in Chrome
hello.hs                     sample program
```

Module inventory (embedded modules):
`node scripts/node-repl-run.js --probe-imports Prelude,Data.Map,...`.
Package-provided modules are exercised through the browser harness, which loads the DB.

Reproduce:

- headless suite: `node scripts/node-test.js`
- feature matrix: `node scripts/feature-probe.js`
- browser flow: `node serve.js`, then open http://localhost:8123/
