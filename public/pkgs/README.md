# Runtime MicroHs packages

The wasm bundle (`../mhs/mhs-embed.wasm`) embeds `base` + `canvhs`. Everything else ships
here as MicroHs packages and is loaded **on demand**.

```
packages/<name>.pkg   serialized MicroHs packages
index.json            manifest: module -> package, package -> dependencies
```

## How loading works

`../packages.js` reads `index.json`, scans the program's `import` lines, maps each module to
its package, closes over the `packages` dependencies, and fetches only the resulting `.pkg`
files. The `<Module>.txt` lookup files MicroHs expects are synthesised from the manifest, so
they are not stored here.

```json
{ "modules":     { "Data.Map": "containers-0.8.pkg", ... },
  "packages":    { "containers-0.8.pkg": ["array-mhs-0.5.8.0.pkg"], ... },
  "embedded":    ["Data.List", "Data.Text", ...],
  "unavailable": [ { "prefix": "Data.Aeson", "reason": "not bundled with this playground" } ] }
```

`embedded` lists the modules the wasm already provides (`base`), and `unavailable` is the
curated set of modules users expect but that cannot be provided here. `packages.js` uses them to
answer an import it cannot satisfy with an accurate explanation instead of a bare
`Module not found`; the rules are edited in `../../scripts/module-support.json`, not here.

The package search path is declared when the compiler boots (`-a/pkgs`) and packages are
written into the virtual FS on demand, so a program importing a module from a package that is
not loaded yet simply loads it and carries on — no REPL restart, no page reload. Within a
session the set only ever grows.

The on-demand write is possible because module lookup happens at import time (`findPkgModule`,
`Compile.hs`), **not** at boot: as long as `/pkgs` is on the package path — even empty — a `.pkg`
and its module maps can be written into the virtual FS later and imported immediately. Verified
with the pinned bundle by `scripts/probe-runtime-loading.js`; see FINDINGS.md "Correction
(verified)".

`base` is embedded in the wasm and must **not** be shipped here; dependencies on it are
filtered out of the manifest.

## Adding a package

The full runbook — including the incremental Docker command that rebuilds only the new package,
and what to check afterwards — is in [`../../BUILD.md`](../../BUILD.md). In short:

1. Build it (see `../../scripts/build-packages-linux.sh`) — it must come from the same MicroHs
   version as the bundle, or its packages will not deserialize. Re-runs are incremental if the
   build DB (`.build/db`) and work dir (`.build/work`) are mounted.
2. Copy `<name>.pkg` into `packages/`. This is also the decision to *ship* it: a `.pkg` that is
   absent from here is simply not in the manifest. (`binary` is built but withheld this way —
   it compiles, yet `Data.Binary.Get` hangs.)
3. Regenerate the manifest: `node scripts/build-manifest.js`.
   It reads the build's module maps and `deps.txt`. Note that `mhs` joins `-L` and `-P` to
   their arguments (`-L<path>`), which is how `deps.txt` is produced.
4. Check the classification still holds: `node scripts/test-manifest.js`.

Nothing else needs to change — the wasm is untouched.
