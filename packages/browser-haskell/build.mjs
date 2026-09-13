#!/usr/bin/env node
/**
 * Build the published package: ESM + IIFE bundles (minified), type definitions, and the
 * runtime assets (the MicroHs wasm bundle and the package set) under dist/.
 *
 * Assets are copied rather than bundled: the wasm is 1.9 MB and the package set is
 * ~11 MB, all of it fetched lazily at runtime from `baseUrl`.
 */
import { build } from 'esbuild';
import { cp, mkdir, readFile, readdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, 'dist');
// The runtime assets are the spike's: the wasm bundle and the package set it ships.
const publicDir = path.resolve(root, '..', '..', 'public');

const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const banner =
  `/*! ${pkg.name} v${pkg.version} | ${pkg.license}\n` +
  ` * Runs Haskell in the browser with MicroHs (Apache-2.0). */`;

const exists = async (p) => {
  try {
    await stat(p);
    return true;
  } catch (err) {
    return false;
  }
};

if (!(await exists(path.join(publicDir, 'mhs', 'mhs-embed.wasm')))) {
  throw new Error(
    'runtime assets are missing: expected ' + path.join(publicDir, 'mhs', 'mhs-embed.wasm'),
  );
}

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

const shared = {
  entryPoints: [path.join(root, 'src', 'index.js')],
  bundle: true,
  minify: true,
  sourcemap: true,
  target: ['es2020'],
  banner: { js: banner },
  legalComments: 'none',
};

await build({
  ...shared,
  format: 'esm',
  outfile: path.join(dist, 'browser-haskell.mjs'),
});

await build({
  ...shared,
  format: 'iife',
  globalName: 'BrowserHaskell',
  outfile: path.join(dist, 'browser-haskell.iife.js'),
});

// Types (hand written: the source is plain JS).
await cp(path.join(root, 'src', 'index.d.ts'), path.join(dist, 'index.d.ts'));

// Runtime assets, laid out exactly as the default baseUrl expects.
await cp(path.join(publicDir, 'mhs'), path.join(dist, 'mhs'), { recursive: true });
await mkdir(path.join(dist, 'pkgs'), { recursive: true });
await cp(path.join(publicDir, 'pkgs', 'index.json'), path.join(dist, 'pkgs', 'index.json'));
await cp(path.join(publicDir, 'pkgs', 'packages'), path.join(dist, 'pkgs', 'packages'), {
  recursive: true,
});

const kb = (bytes) => (bytes / 1024).toFixed(1) + ' KB';
const mb = (bytes) => (bytes / 1024 / 1024).toFixed(1) + ' MB';

const bundleSize = (await stat(path.join(dist, 'browser-haskell.mjs'))).size;
const iifeSize = (await stat(path.join(dist, 'browser-haskell.iife.js'))).size;
const wasmSize = (await stat(path.join(dist, 'mhs', 'mhs-embed.wasm'))).size;
const pkgFiles = await readdir(path.join(dist, 'pkgs', 'packages'));
const pkgBytes = (
  await Promise.all(pkgFiles.map((f) => stat(path.join(dist, 'pkgs', 'packages', f))))
).reduce((sum, s) => sum + s.size, 0);

console.log('dist/browser-haskell.mjs      ' + kb(bundleSize));
console.log('dist/browser-haskell.iife.js  ' + kb(iifeSize));
console.log('dist/mhs/mhs-embed.wasm       ' + mb(wasmSize));
console.log('dist/pkgs/                    ' + mb(pkgBytes) + ' in ' + pkgFiles.length + ' packages (lazy)');
console.log('\nbuilt ' + pkg.name + '@' + pkg.version);
