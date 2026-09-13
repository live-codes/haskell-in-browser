# @live-codes/browser-haskell

Run Haskell entirely in the browser. Powered by [MicroHs](https://github.com/augustss/MicroHs)
compiled to WebAssembly — no server, no install, ~1.8 MB of wasm plus the packages a program
actually imports.

```js
import { createHaskell } from '@live-codes/browser-haskell';

const haskell = await createHaskell();
const result = await haskell.run({
  code: 'main :: IO ()\nmain = interact (unlines . map reverse . lines)',
  stdin: 'hello\nworld\n',
});

result.stdout;    // "olleh\ndlrow\n"
result.stderr;    // ""
result.error;     // null
result.exitCode;  // 0
```

## Install

```sh
npm install @live-codes/browser-haskell
```

Or load it from a CDN — no bundler required:

```html
<script src="https://cdn.jsdelivr.net/npm/@live-codes/browser-haskell/dist/browser-haskell.iife.js"></script>
<script>
  const haskell = await BrowserHaskell.createHaskell();
  const { stdout, error, exitCode } = await haskell.run({ code: 'main = putStrLn "hi"' });
</script>
```

The IIFE build exposes `BrowserHaskell` and works out of the box: with no `baseUrl` it loads its
assets from the directory it was served from.

## API

### `createHaskell(options?) → Promise<Haskell>`

Boots MicroHs (~0.5–2 s; the wasm is instantiated and the REPL reaches its prompt) and returns an
instance. Do this once per page or worker.

| option | default | meaning |
| --- | --- | --- |
| `baseUrl` | this module's directory | Where the assets are: `mhs/mhs-embed.js` (+ `.wasm`) and `pkgs/index.json` (+ `pkgs/packages/`). |
| `wasmUrl` | `baseUrl + 'mhs/mhs-embed.js'` | Full URL of the compiler's JS glue. |
| `packagesUrl` | `baseUrl + 'pkgs/'` | Directory holding `index.json` and `packages/`. |
| `importmap` | `{}` | Packages by module name, for ones that are not bundled: `{ 'My.Module': 'https://…/my-pkg.pkg' }`. See below. |
| `timeout` | `60000` | Per-run timeout in ms. |
| `onLog` | – | `(message) => void` for diagnostics. |

### `haskell.run({ code, stdin?, timeout? }) → Promise<RunResult>`

Compiles and runs `code` as a `Main` module.

| field | meaning |
| --- | --- |
| `stdout` | what the program wrote to stdout |
| `stderr` | what the program wrote to stderr |
| `error` | compile errors and runtime exceptions, or `null` |
| `output` | stdout, stderr and diagnostics together, in the order produced |
| `exitCode` | `0` on success, `1` on error, `124` on timeout |
| `packages` | MicroHs package files that had to be fetched for this run |
| `durationMs` | wall-clock time for the run |

`import`ed modules that cannot be satisfied are reported *before* anything is compiled, with a
reason rather than a bare `Module not found`:

```js
const r = await haskell.run({ code: 'import Data.Aeson\nmain = pure ()' });
r.error;   // "Not available in this playground:\n  Data.Aeson — not bundled with this playground\n…"
r.exitCode; // 1
```

### `haskell.dispose()`

Releases the instance. Browsers cannot unload a wasm module, so this drops the library's
references rather than freeing memory — use one instance per page or worker, and reuse it.

## stdin

The web build of MicroHs has no usable file descriptor 0: `getLine` throws
`Handle(stdin): end of file`, and characters pushed at the REPL are read by the *REPL*, not by the
running program. So `stdin` is injected as source instead, in two ways:

1. `lcInput :: String`, `lcInputLines :: [String]`, `lcInputWords :: [String]` — always available
   when `stdin` is passed, no imports needed.
2. Prelude's `getLine`, `readLn`, `getContents` and `interact` are **shadowed** by equivalents
   that consume the same input, so ordinary programs work unchanged:

```js
await haskell.run({
  code: `
main :: IO ()
main = do
  [n, k] <- fmap (map read . words) getLine
  print (n + k :: Int)`,
  stdin: '2 40\n',
}); // stdout: "42"
```

Imports of `Data.IORef` and `System.IO.Unsafe` are hoisted to the top of your module to make that
work; if your program defines `getLine`, `readLn`, `getContents`, `interact` or `lcInput` itself,
yours is kept and ours is not injected.

## What is available

The wasm embeds MicroHs's `base` (which is larger than GHC's — it includes `bytestring`, `text`,
`deepseq`, `directory`, `stm`, `process`, `hashable`) plus `canvhs`. On top of that, 43 packages
are fetched **on demand** — only what a program imports:

`containers`, `array`, `transformers`, `mtl`, `exceptions`, `filepath`, `os-string`, `time`,
`random`, `splitmix`, `unordered-containers`, `async`, `parsec`, `pretty`, `xhtml`, `semigroups`,
`fgl`, `fingertree`, `heaps`, `psqueues`, `tagsoup`, `edit-distance`, `Diff`, `data-ordlist`,
`dlist`, `split`, `monad-loops`, `prettyprinter`, `numbers`, `parallel`, `HUnit`, `QuickCheck`,
`hspec` (+ `hspec-core`, `hspec-expectations`, `hspec-discover`, `quickcheck-io`, `call-stack`,
`ansi-terminal`, `ansi-terminal-types`, `colour`, `haskell-lexer`, `ghc-compat`).

Modules that can never work here (`Language.Haskell.TH`, `GHC.*`, `System.Posix.*`, `Network.*`,
`Data.Vector`, `Data.Aeson`, `Control.Lens`, …) are reported with a reason. `Data.Binary` compiles
but its reader loops forever, so it is deliberately withheld rather than shipped as a landmine.

### Custom packages (`importmap`)

```js
const haskell = await createHaskell({
  importmap: { 'My.Module': 'https://example.com/my-module.pkg' },
});
```

The `.pkg` is a MicroHs package, and it must be built by the same MicroHs version as the bundled
compiler or it will not deserialize. The manifest cannot know anything about packages it does not
ship, so list their MicroHs dependencies in the `importmap` too.

## Assets

`dist/` contains the bundles, the type definitions, and the runtime assets:

```
dist/browser-haskell.mjs        ESM bundle (minified)
dist/browser-haskell.iife.js    IIFE bundle, global `BrowserHaskell` (minified)
dist/index.d.ts                 types
dist/mhs/mhs-embed.js|.wasm     MicroHs compiler (pinned 0.16.6.0)
dist/pkgs/index.json            package manifest
dist/pkgs/packages/*.pkg        43 packages, ~11 MB, fetched lazily
```

Point `baseUrl` at a copy of `dist/` on your own origin, or straight at a CDN:

```js
const haskell = await createHaskell({
  baseUrl: 'https://cdn.jsdelivr.net/npm/@live-codes/browser-haskell/dist/',
});
```

If your page is cross-origin isolated (`COEP: require-corp`), make sure the host serving the
assets sends the matching CORS/CORP headers — jsDelivr does.

## Limits

- **Browser only** (window or worker). There is no Node build: the compiler glue needs a DOM or a
  worker scope.
- **One instance per page/worker.** The Emscripten glue is a classic script that installs globals,
  so loading it twice in the same context is not supported. Everything else is reusable — run as
  many programs as you like through one instance.
- **No interrupt.** A program that loops forever blocks the main thread and freezes the page; that
  is a MicroHs/JavaScript limitation, not something this library can work around. A run that
  merely takes too long rejects with `exitCode: 124` and poisons the instance (create a new one).
- **Execution is REPL-based.** MicroHs's web bundle cannot compile-and-run in batch mode, so each
  run is `import Main` → `:reload` → `:main` behind a sentinel prompt. This is why runs take about
  a second even for tiny programs.
- Template Haskell, type families, GHC internals and anything platform-specific are absent.

## Development

```sh
cd packages/browser-haskell
npm install
npm run build      # dist/ — bundles, types and assets
```

Open `test/index.html` (ESM) or `test/iife.html` (IIFE) to smoke-test the built output against the
real wasm and packages — serving from the repository root:

```sh
node serve.js 8124 .
# → http://localhost:8124/packages/browser-haskell/test/index.html
```

## License

MIT. MicroHs itself is Apache-2.0; its wasm bundle is redistributed here unmodified, and the
package set in `dist/pkgs` is built from upstream Haskell packages (see the repository's
`PACKAGES.md`).
