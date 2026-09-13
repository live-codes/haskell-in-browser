# Browser Haskell

A client-side Haskell playground: a Haskell 2010-subset interpreter compiled to WebAssembly, with
a REPL-driven runner, on-demand package loading, and a harness that runs real programs in the
browser. This is the spike behind adding a `haskell-wasm` language to LiveCodes; it runs entirely
client-side, no server.

**Engine: [MicroHs](https://github.com/augustss/MicroHs)** — not GHC-in-the-browser. 1.9 MB of
wasm instead of ~49 MB, actively maintained, and it works on the main thread in Chrome. The
trade-offs (no interrupt, terse diagnostics, no Template Haskell) are documented honestly in
`FINDINGS.md`.

## npm package

[`packages/browser-haskell/`](packages/browser-haskell) packages this runtime as
**`@live-codes/browser-haskell`**: client-side Haskell behind two calls, as ESM and IIFE bundles.

```js
import { createHaskell } from "@live-codes/browser-haskell";

const haskell = await createHaskell();
const { stdout, stderr, error, exitCode } = await haskell.run({
  code: 'main = putStrLn "hi"',
});
```

It is built _from_ the harness here — `npm run build` copies the pinned wasm bundle and the package
set out of `public/` into `packages/browser-haskell/dist/`. Its README covers the API, the options
(`baseUrl`, `importmap`, …), the assets and the limits.

## Quick start

```bash
node serve.js                 # then open http://localhost:8123/
```

The harness takes a program, an input string, and a mode (`run main` / `eval expression`).

Verify the package machinery without a browser:

```bash
node scripts/test-manifest.js           # module classification (52 checks)
node scripts/node-test.js               # REPL protocol, headless (5 cases)
node scripts/probe-runtime-loading.js   # module loading at runtime (4 cases)
```

## Docs

| file                                                                     | what it covers                                                                    |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| **[BUILD.md](BUILD.md)**                                                 | how to build/update the wasm bundle, the packages, and the manifest — the runbook |
| **[PACKAGES.md](PACKAGES.md)**                                           | what can and cannot be `import`ed, and why                                        |
| **[FINDINGS.md](FINDINGS.md)**                                           | the spike results: what works, what was wrong, what a learner loses               |
| [public/pkgs/README.md](public/pkgs/README.md)                           | the package directory and manifest format                                         |
| [public/mhs/VERSION.md](public/mhs/VERSION.md)                           | the pinned wasm bundle, its hashes, and the one patch never to apply              |
| [packages/browser-haskell/README.md](packages/browser-haskell/README.md) | the published npm package: API, options, assets, limits                           |

## Layout

```
public/          the harness: runners, lazy package loader, canvas glue, pinned wasm bundle
public/pkgs/     43 packages (11 MB) + index.json — fetched on demand, never up front
scripts/         package build (Docker), manifest generator, headless tests, probes
packages/        the npm package: @live-codes/browser-haskell (ESM + IIFE; see its README)
.build/          build caches: toolchain, package DB, staged output (see BUILD.md)
serve.js         zero-dependency static server (a server is required: workers/wasm need http).
                 Its third argument is the root, so `node serve.js 8124 .` serves this whole repo.
```

## Status

Spike complete. The main-thread path is verified end to end in Chrome, including `containers`,
`mtl`, `random`, `time`, `parsec`, `pretty`, `xhtml`, the test frameworks `HUnit`, `QuickCheck`
and `hspec`, and the graph/data-structure/parsing batch — `fgl`, `fingertree`, `heaps`,
`psqueues`, `tagsoup`, `edit-distance`, `Diff`, `data-ordlist`, `dlist`, `split`, `monad-loops`,
`prettyprinter`, `numbers` and `parallel`.

Known limits, in short: an infinite program freezes the tab (no interrupt on the main thread —
recover by reloading), error messages are terse, and Template Haskell and type families are absent.
Program stdin does not exist at the OS level (fd 0 is EOF), so input is injected as source: the
harness exposes `lcInput`, and the npm package additionally shims `getLine`, `readLn`, `getContents`
and `interact` so ordinary programs work. `FINDINGS.md` has the detail; `PACKAGES.md` has the
import-by-import picture.
