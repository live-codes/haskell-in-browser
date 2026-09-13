# Haskell in the browser — MicroHs spike

A client-side Haskell playground: a Haskell 2010-subset interpreter compiled to WebAssembly, with
a REPL-driven runner, on-demand package loading, and a harness that runs real programs in the
browser. This is the spike behind adding a `haskell-wasm` language to LiveCodes; it runs entirely
client-side, no server.

**Engine: [MicroHs](https://github.com/augustss/MicroHs)** — not GHC-in-the-browser. 1.9 MB of
wasm instead of ~49 MB, actively maintained, and it works on the main thread in Chrome. The
trade-offs (no interrupt, terse diagnostics, no Template Haskell) are documented honestly in
`FINDINGS.md`.

## Quick start

```bash
node serve.js                 # then open http://localhost:8123/
```

The harness takes a program, an input string, and a mode (`run main` / `eval expression`).

Verify the package machinery without a browser:

```bash
node scripts/test-manifest.js   # module classification (37 checks)
node scripts/node-test.js       # REPL protocol, headless (5 cases)
```

## Docs

| file | what it covers |
| --- | --- |
| **[BUILD.md](BUILD.md)** | how to build/update the wasm bundle, the packages, and the manifest — the runbook |
| **[PACKAGES.md](PACKAGES.md)** | what can and cannot be `import`ed, and why |
| **[FINDINGS.md](FINDINGS.md)** | the spike results: what works, what was wrong, what a learner loses |
| [public/pkgs/README.md](public/pkgs/README.md) | the package directory and manifest format |
| [public/mhs/VERSION.md](public/mhs/VERSION.md) | the pinned wasm bundle, its hashes, and the one patch never to apply |

## Layout

```
public/          the harness: runners, lazy package loader, canvas glue, pinned wasm bundle
public/pkgs/     29 packages (8 MB) + index.json — fetched on demand, never up front
scripts/         package build (Docker), manifest generator, headless tests, probes
.build/          build caches: toolchain, package DB, staged output (see BUILD.md)
serve.js         zero-dependency static server (a server is required: workers/wasm need http)
```

## Status

Spike complete. The main-thread path is verified end to end in Chrome, including `containers`,
`mtl`, `random`, `time`, `parsec`, `pretty`, `xhtml`, and the test frameworks `HUnit`,
`QuickCheck` and `hspec`.

Known limits, in short: an infinite program freezes the tab (no interrupt on the main thread —
recover by reloading), error messages are terse, Template Haskell and type families are absent,
and program stdin cannot be read (input is exposed as `lcInput` instead). `FINDINGS.md` has the
detail; `PACKAGES.md` has the import-by-import picture.
