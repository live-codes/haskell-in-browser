import { MicroHs } from './repl.js';

/**
 * @live-codes/browser-haskell — run Haskell in the browser.
 *
 *   import { createHaskell } from '@live-codes/browser-haskell';
 *
 *   const haskell = await createHaskell();            // boots MicroHs (~1-2s)
 *   const result = await haskell.run({ code: 'main = putStrLn "hi"', stdin: '' });
 *   result.stdout;    // "hi\n"
 *   result.error;     // compile errors / exceptions, or null
 *   result.exitCode;  // 0, 1, or 124 on timeout
 *
 * Everything is client-side: a wasm build of MicroHs plus lazily fetched MicroHs
 * packages. Assets (the wasm bundle and the package set) are looked up next to this
 * module by default; point `baseUrl` at wherever you host them.
 */

/**
 * Where this file lives, so a default asset URL can be derived. Captured at load time
 * because `document.currentScript` is only meaningful then (IIFE build); the ESM build
 * uses `import.meta.url`.
 */
const SELF_DIR = (() => {
  if (typeof document !== 'undefined' && document.currentScript && document.currentScript.src) {
    return dirOf(document.currentScript.src);
  }
  try {
    return dirOf(import.meta.url);
  } catch (err) {
    // Not a module (IIFE build without a script tag): fall back to the page URL.
  }
  if (typeof location !== 'undefined' && location.href) return dirOf(location.href);
  return '';
})();

function dirOf(url) {
  return String(url).slice(0, String(url).lastIndexOf('/') + 1);
}

const withSlash = (url) => (String(url).endsWith('/') ? String(url) : String(url) + '/');

/**
 * Create a MicroHs instance.
 *
 * @param {object} [options]
 * @param {string} [options.baseUrl] Where the assets live: `mhs/mhs-embed.js` (+ .wasm)
 *   and `pkgs/index.json` (+ `pkgs/packages/*.pkg`). Defaults to this module's directory.
 * @param {string} [options.wasmUrl] Full URL of `mhs-embed.js` (overrides baseUrl).
 * @param {string} [options.packagesUrl] Directory containing `index.json` and
 *   `packages/` (overrides baseUrl).
 * @param {Object<string,string>} [options.importmap] Extra packages by module name,
 *   e.g. `{ 'My.Module': 'https://example.com/my-pkg.pkg' }`. The `.pkg` must be built by
 *   the same MicroHs version, and any MicroHs dependencies it has must be mapped too.
 * @param {number} [options.timeout] Per-run timeout in ms (default 60000).
 * @param {(message: string) => void} [options.onLog] Diagnostic logging.
 * @returns {Promise<MicroHs>}
 */
export async function createHaskell(options) {
  const opts = options || {};
  const baseUrl = withSlash(opts.baseUrl || SELF_DIR);
  const repl = new MicroHs({
    ...opts,
    wasmUrl: opts.wasmUrl || baseUrl + 'mhs/mhs-embed.js',
    packagesUrl: opts.packagesUrl || baseUrl + 'pkgs/',
  });
  await repl.boot();
  return repl;
}

export { MicroHs };
export default { createHaskell, MicroHs };
