# Browser Haskell

Run Haskell **entirely in the browser** — a compiler, a package set and a runner that turn a
program plus an input string into `stdout`, `stderr`, compile errors and an exit code. No server,
no install, no upload.

It is built on **[MicroHs](https://github.com/augustss/MicroHs)** (an extended Haskell 2010
implementation) compiled to WebAssembly — not GHC-in-the-browser. That is the whole reason it
fits: **1.9 MB** of wasm against GHC's ~49 MB, and it runs on the main thread in Chrome today.

Two things live here:

- **`public/`** — the spike harness: a page that runs programs and shows what the machine is
  doing (package loading, REPL traffic, timings).
- **[`packages/browser-haskell/`](packages/browser-haskell)** — the same runtime packaged as the
  npm library **`@live-codes/browser-haskell`**.

This is the runtime behind adding a `haskell` language to
[LiveCodes](https://livecodes.io).

## Demo

```bash
node serve.js          # → http://localhost:8123/
```

Open that page and pick a **demo** from the dropdown — hello world, program input, `containers`,
`mtl`, `random`, QuickCheck, two canvhs drawings, expression evaluation, and a deliberately failing
program — then edit the code and press **Run**. The harness takes a program, an input string and a
mode (`run main` / `eval expression`), and the log pane shows exactly which packages were fetched
for the run. A server is required — the wasm build needs HTTP, `file://` will not work.

To smoke-test the **built npm package** instead (ESM and IIFE builds against the real wasm and
packages):

```bash
node serve.js 8124 .
# → http://localhost:8124/packages/browser-haskell/test/index.html
#   http://localhost:8124/packages/browser-haskell/test/iife.html
```

## npm package

```sh
npm install @live-codes/browser-haskell
```

```js
import { createHaskell } from "@live-codes/browser-haskell";

const haskell = await createHaskell(); // ~1.9 MB of wasm, once per page
const result = await haskell.run({
  code: `
main :: IO ()
main = do
  [n, k] <- fmap (map read . words) getLine
  print (n + k :: Int)`,
  stdin: "2 40\n",
});

result.stdout; // "42\n"
result.error; // null
result.exitCode; // 0
```

One call to boot, one call to run; `dispose()` when you are done with the instance.

**Options** — `createHaskell({ baseUrl, wasmUrl, packagesUrl, importmap, timeout, onLog })`.
`baseUrl` points at wherever you copied `dist/` (your own origin, or a CDN); with no `baseUrl`
each build loads its assets from the directory it was served from. `importmap` maps a module name
to a MicroHs `.pkg` you host yourself.

**Result** — `{ stdout, stderr, error, output, exitCode, packages, durationMs }`. `output` is
stdout, stderr and diagnostics interleaved in the order produced; `packages` lists what that run
had to fetch; `exitCode` is `0`, `1` on error, `124` on timeout.

No bundler? Take the IIFE build and the global `BrowserHaskell`:

```html
<script src="https://cdn.jsdelivr.net/npm/@live-codes/browser-haskell/dist/browser-haskell.iife.js"></script>
<script>
  const haskell = await BrowserHaskell.createHaskell();
  console.log((await haskell.run({ code: 'main = putStrLn "hi"' })).stdout);
</script>
```

The package is ~13 KB of glue plus the assets it loads lazily. Its
[README](packages/browser-haskell/README.md) covers the full API, the asset layout and the
cross-origin-isolation caveat.

## Features

- **Client-side, main thread.** The REPL runs on the page's own thread — no worker, no server; verified in Chrome.
- **43 packages, fetched on demand.** 11 MB of Haskell libraries ship with the runtime, but only
  what a program actually `import`s is downloaded — boot cost does not grow as packages are added.
  `containers`, `mtl`, `transformers`, `array`, `parsec`, `pretty`, `xhtml`, `time`,
  `random`/`splitmix`, `unordered-containers`, `async`, `fgl`, `fingertree`, `heaps`, `psqueues`,
  `tagsoup`, `edit-distance`, `Diff`, `data-ordlist`, `dlist`, `split`, `monad-loops`,
  `prettyprinter`, `numbers`, `parallel`, `semigroups`, `exceptions`, `filepath`/`os-string`,
  `haskell-lexer`, `ghc-compat`, and the test frameworks `HUnit`, `QuickCheck`, `hspec`.
- **196 modules embedded** in the wasm — `base` here is bigger than GHC's, and already includes
  `Data.Text`, `Data.ByteString`, `Data.Sequence`, `Data.Map`, `Control.Concurrent`, `STM`,
  `Data.Typeable`/`Data.Data`, `Data.Hashable`, `directory` and `process`.
- **Accurate "not available" errors.** Imports that cannot be satisfied are reported _before_
  compilation with a reason — `Data.Aeson` is "not bundled", `Language.Haskell.TH` is "Template
  Haskell is not supported by MicroHs", `Data.Binary` is withheld because its reader loops forever
  — instead of a bare `Module not found`.
- **Working stdin.** MicroHs's web build has no usable file descriptor 0, so input is injected as
  source: `lcInput` / `lcInputLines` / `lcInputWords` are always available, and `getLine`,
  `readLn`, `getContents` and `interact` are shadowed so ordinary programs run unchanged.
- **Graphics.** `canvhs` is embedded, so a program can draw to a canvas
  ([proof](canvhs-proof.png)).
- Small, boring API surface: `createHaskell(opts)` → `run({ code, stdin })` → a result object.

## Language support

MicroHs is Haskell 2010
with most GHC extensions _always on_, minus a few modern ones. What that means in practice, from
the probes in `scripts/feature-probe.js`:

| Works (21 probes)                                                                                  | Does not work                                                         |
| -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| ADTs + `deriving`, typeclasses, higher-kinded types, `Foldable`/`Traversable`                      | **`TypeFamilies`** (type/data families)                               |
| **GADTs**, **RankNTypes**, **TypeApplications**, `PatternSynonyms`                                 | **Template Haskell / QuasiQuotes**                                    |
| `OverloadedStrings` (+`Data.Text`), `LambdaCase`, `MultiWayIf`, record dot syntax                  | **`DeriveGeneric`** (`undefined type: Generic`)                       |
| `MultiParamTypeClasses` + fundeps, `ExistentialQuantification`                                     | **`ApplicativeDo`** (`do` is `Monad`-only)                            |
| `DeriveFunctor`, `GeneralisedNewtypeDeriving`, `StandaloneDeriving`                                | `Arrows`/`proc`, `ImplicitParams`, `RebindableSyntax`, unboxed tuples |
| list comprehensions, laziness, `case`/guards/`where`, `ST`/`STRef`, `Control.Exception`, `DeepSeq` |                                                                       |

For a learner or a competitive-programming snippet, that covers an intro-to-intermediate course:
an import probe of the ~97 modules such a course touches scored **93/97**, and the gaps are
`megaparsec`, `vector`, `lens` and `aeson`.

Two caveats worth knowing before you trust a program here:

- **Extensions are always on**, so code GHC would reject on purity grounds still compiles.
- **Many things that should be errors are not reported.** Like all such interpreters it is more
  permissive than the standard, not stricter.

`FINDINGS.md` records the full matrix and the wiki-noted deviations; `PACKAGES.md` has the
import-by-import picture.

## Limitations

- **Browser only.** There is no Node build — the Emscripten glue wants a DOM.
- **One instance per page.** The glue is a classic script that installs globals, so
  loading it twice in the same context is unsupported. Runs themselves are unlimited: reuse one
  instance.
- **No interrupt.** A program that loops forever blocks the page and freezes the tab — a
  MicroHs/JavaScript limitation, not something the library can route around. A run that merely
  takes too long rejects with `exitCode: 124` and leaves the instance unusable; create a new one.
- **Execution is REPL-based.** MicroHs's web bundle cannot compile-and-run in batch mode, so each
  run is `import Main` → `:reload` → `:main` behind a sentinel prompt. Even a trivial program costs
  roughly a second.
- **Terse diagnostics**, in MicroHs's own format (`"Data/List.hs",389:11`) rather than GHC's.
- **No Template Haskell, type families or `Generic` deriving** (see above).
- `Data.Binary` is deliberately not shipped: `Data.Binary.Put` works, `Data.Binary.Get`/`decode`
  never return.

## Layout

```
public/          the harness: runners, lazy package loader, canvas glue, pinned wasm bundle
public/mhs/      MicroHs compiler as wasm (95 KB glue + 1.79 MB wasm), pinned 0.16.6.0
public/pkgs/     43 packages (11 MB) + index.json — fetched on demand, never up front
scripts/         package build (Docker), manifest generator, headless tests, probes
packages/        the npm library: @live-codes/browser-haskell (ESM + IIFE; see its README)
.build/          build caches: toolchain, package DB, staged output (see BUILD.md) — derived
serve.js         zero-dependency static server; `node serve.js [port] [root]`
```

## Docs

| file                                                                     | what it covers                                                            |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| **[BUILD.md](BUILD.md)**                                                 | how to build/update the wasm, the packages and the manifest — the runbook |
| **[PACKAGES.md](PACKAGES.md)**                                           | what can and cannot be `import`ed, and why                                |
| **[FINDINGS.md](FINDINGS.md)**                                           | the spike results: what works, what was wrong, what a learner loses       |
| [public/pkgs/README.md](public/pkgs/README.md)                           | the package directory and manifest format                                 |
| [public/mhs/VERSION.md](public/mhs/VERSION.md)                           | the pinned wasm bundle, its hashes, and the one patch never to apply      |
| [packages/browser-haskell/README.md](packages/browser-haskell/README.md) | the npm library: API, options, assets, limits                             |

## Verifying

Everything here is meant to be _run_, not imported. None of these need a browser:

| what                                   | command                                               |
| -------------------------------------- | ----------------------------------------------------- |
| package classification / manifest      | `node scripts/test-manifest.js` — 52 checks           |
| REPL protocol, headless                | `node scripts/node-test.js` — 5 cases                 |
| module loading at runtime              | `node scripts/probe-runtime-loading.js` — 4 scenarios |
| language feature matrix                | `node scripts/feature-probe.js` — 21/26               |
| refresh `deps.txt` from an existing DB | `bash scripts/dump-deps.sh` (in the build container)  |
| the real thing                         | `node serve.js` → http://localhost:8123/              |

A package that compiles can still be broken — `binary` compiles and its reader never returns.
Verify by running, which is why the package list is honest about what was exercised.

## Status

Spike complete. The main-thread path is verified end to end in Chrome: `containers`, `mtl`,
`random`, `time`, `parsec`, `pretty`, `xhtml`, the test frameworks (`HUnit`, `QuickCheck`,
`hspec`), and the graph/data-structure/parsing batch (`fgl`, `fingertree`, `heaps`, `psqueues`,
`tagsoup`, `edit-distance`, `Diff`, `data-ordlist`, `dlist`, `split`, `monad-loops`,
`prettyprinter`, `numbers`, `parallel`).

Next: the LiveCodes `haskell-wasm` language entry, which this package was shaped for.

## License

MIT © Hatem Hosny. MicroHs is Apache-2.0 and its wasm bundle is redistributed unmodified; the
packages under `public/pkgs` are built from upstream Haskell sources and keep their own licences.
See [LICENSE](LICENSE).
