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
| **stdin not supported** | The program's own `getLine` is not wired; only REPL commands can be typed. Unverified/unsupported for v1. |
| **Module caching** | Mitigated by `:reload`, but the REPL remains a stateful, accumulating session. |
| **Not GHC** | MicroHs is an extended Haskell 2010 implementation at ~GHCi speed with its own error messages (`"Data/List.hs",389:11`). Many extensions *do* work (GADTs, RankNTypes, TypeApplications, OverloadedStrings, record dot); `TypeFamilies`, Template Haskell and `DeriveGeneric` do not. Packages outside the embedded set are unavailable in the browser (see capability profile). |
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

### Library modules — 76/97 probed available

Present: `Prelude`, `Data.List/Maybe/Char/Either/Tuple`, **`Data.Text` (+Lazy, IO,
Encoding)**, **`Data.ByteString` (+Char8, Lazy, Short, Builder)**, `Data.Ratio`,
`Data.Complex`, `Data.Bits`, `Data.Ix`, `Data.Foldable/Traversable`, `Data.List.NonEmpty`,
`Data.Hashable`, `Data.STRef`, `Data.IORef`, `Data.Typeable`, `Data.Data`, `Data.Dynamic`,
`Data.Coerce`, `Data.Bifunctor`, `Data.String.Interpolate`, `GHC.Generics`,
`Control.Monad.ST`, `Control.Applicative/Arrow/Category/Exception/DeepSeq/Monad.Fix`,
`Control.Concurrent(+STM)`, `System.IO/Environment/Exit/Directory/Process/Cmd/Info/Mem/Timeout/CPUTime`,
`Text.Printf`, `Text.Read`, `Text.ParserCombinators.ReadP`, `Numeric`, `Data.Version`,
`Debug.Trace`, `Foreign*`, `Unsafe.Coerce`, `Graphics.CanvHs`.

Missing (verified "Module not found"):
`Data.Map`, `Data.Set`, `Data.Sequence`, `Data.IntMap`, `Data.Tree` (**containers**);
`Control.Monad.State/Reader/Writer/Except/RWS` (**mtl**);
`Data.Array*` (**array**); `Text.Parsec`, `Text.Megaparsec`;
`System.Random`; `Data.Time`; `Test.HUnit`, `Test.QuickCheck`, `Test.Hspec`;
`Data.Vector`, `Control.Lens`, `Data.Aeson`.

**Important nuance:** those missing packages *do* work with MicroHs locally
(`Makefile.packages` builds containers, mtl, array, transformers, parsec, QuickCheck,
HUnit, hspec, random, binary, fingertree, heaps, fgl, …). The gap is only that the
browser bundle embeds `base` + `canvhs`. Which packages get embedded is a bundling
decision, so `Data.Map`/`mtl` could be closed at the cost of download size.

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
2. **Missing tutorial staples:** no `Data.Map`/`Data.Set` (word-count, memoisation,
   graph examples), no `Control.Monad.State` (monad-transformer chapters), no
   `hspec`/`HUnit`/`QuickCheck` (testing chapters). All fixable by embedding more packages.
3. **Weak safety net:** things that should be errors often are not, so a learner gets
   less feedback than GHC would give.

Beyond that, the language surface is genuinely strong — GADTs, RankNTypes,
TypeApplications, OverloadedStrings and record dot all work, so even an advanced reader
("Thinking with Types"-style material) is mostly served.

### Competitive programming?

Effectively out of scope:

- **No stdin.** Verified: the program's own `getLine`/`getContents` cannot be fed; only
  REPL commands are typed. Most CP problems are input-driven, so this alone is fatal.
- **Speed.** Execution is a combinator interpreter, ~GHCi class — orders of magnitude
  slower than compiled GHC. CP solutions are written for compiled speed.
- **No data structures.** No `Data.Map`/`Set`/`Sequence`, and `Data.Array` is missing
  (it lives in the `array-mhs` package), so the usual toolkit is unavailable.
- No fast-IO idioms (`ByteString` exists, but not wired to stdin), no seeking.

### Sharing snippets / playground use

- Sharing itself is unaffected — LiveCodes already handles URLs, gists, snippets, embeds;
  the viewer just pays one ~1.9 MB download and a ~2.4–4.5 s boot.
- **Portability is the catch in both directions:** extensions are always on and the
  library set differs, so a snippet written here may not compile in GHC (and vice versa).
  Anything restricted to the shared core (Prelude, `Data.List/Maybe/Text/ByteString`,
  typeclasses, ADTs, folds) travels fine.
- Interactive snippets (reading input) will not work until stdin is wired.
- Randomness and dates are unavailable (`System.Random`, `Data.Time`), so clock/RNG-based
  demos won't run; `System.CPUTime` exists but not `Data.Time`.



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
public/index.html          harness UI (engine/mode/timeout, source, output, canvas, log)
public/repl-runner.js      main-thread REPL driver (verified in Chrome)
public/worker-runner.js    worker client with boot+run timeout (worker itself unreliable)
public/haskell-worker.js   worker-side REPL driver + diagnostics
public/canvhs-glue.js      Graphics.CanvHs JS glue (canvas, rAF, Web Audio)
public/mhs/                pinned bundle + VERSION.md
scripts/node-repl-run.js   Node REPL driver — reproduces the browser protocol headlessly
scripts/node-test.js       headless suite (5/5 passing)
scripts/feature-probe.js   language-feature matrix (21/26) — `node scripts/feature-probe.js`
scripts/node-run.js        Node probe for the batch/argv paths (documents inertness)
serve.js                   zero-dependency static server (node serve.js [port])
canvhs-proof.png           screenshot: Graphics.CanvHs drawing in Chrome
hello.hs                   sample program
```

Reproduce:

- headless protocol: `node scripts/node-test.js`
- browser flow: `node serve.js`, then open http://localhost:8123/
