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
{ "modules":  { "Data.Map": "containers-0.8.pkg", ... },
  "packages": { "containers-0.8.pkg": ["array-mhs-0.5.8.0.pkg"], ... } }
```

The package search path is fixed when the compiler boots, so a program that imports a module
from a package that is not loaded triggers a reload with the enlarged set (see
`../index.html` `RESUME_KEY`). The set only ever grows, so switching between programs does not
reload repeatedly.

`base` is embedded in the wasm and must **not** be shipped here; dependencies on it are
filtered out of the manifest.

## Adding a package

1. Build it (see `../../scripts/build-packages-linux.sh`) — it must come from the same MicroHs
   version as the bundle, or its packages will not deserialize.
2. Copy `<name>.pkg` into `packages/`.
3. Regenerate the manifest: `powershell -File scripts/build-manifest.ps1`.
   It reads the build's module maps and `deps.txt`. Note that `mhs` joins `-L` and `-P` to
   their arguments (`-L<path>`), which is how `deps.txt` is produced.

Nothing else needs to change — the wasm is untouched.
