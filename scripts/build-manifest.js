#!/usr/bin/env node
'use strict';

/**
 * Build public/pkgs/index.json — the lazy-loading manifest — from a package DB build.
 *
 *   { "modules":   { "Data.Map": "containers-0.8.pkg", ... },   // package-provided
 *     "packages":  { "containers-0.8.pkg": ["array-mhs-0.5.8.0.pkg"], ... },
 *     "embedded":  ["Data.List", ...],                          // provided by the wasm (base)
 *     "unavailable": [ { prefix, reason } ] }                   // curated, see module-support.json
 *
 * `embedded` and `unavailable` let the runtime tell "needs a package" apart from
 * "not available here", instead of both looking like a missing package.
 *
 * Inputs:
 *   --maps  <dir>   containing mhs-<version>/ with the module maps
 *                   (path = module, content = package file name)
 *   --deps  <file>  "<pkg file>|<dep name-version> <dep name-version> ..."
 *   --pkgs  <dir>   the shipped package dir (public/pkgs) — only packages present
 *                   there are listed; `base` is embedded in the wasm and excluded.
 *   --support <file>  curated module-support.json (default: scripts/module-support.json)
 *
 * Usage:
 *   node scripts/build-manifest.js [--maps .build/db] [--deps .build/pkgs/deps.txt]
 */

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};

const pkgDir = path.resolve(arg('--pkgs', path.join(root, 'public/pkgs')));
const mapsDir = path.resolve(arg('--maps', path.join(root, '.build/db')));
const depsFile = path.resolve(arg('--deps', path.join(root, '.build/pkgs/deps.txt')));
const supportFile = path.resolve(arg('--support', path.join(root, 'scripts/module-support.json')));
const version = arg('--version', '0.16.6.0');

const mapRoot = path.join(mapsDir, 'mhs-' + version);
for (const [what, p] of [['module maps', mapRoot], ['dependency dump', depsFile]]) {
  if (!fs.existsSync(p)) throw new Error(`no ${what} at ${p}`);
}

const packagesDir = path.join(pkgDir, 'packages');
const shipped = new Set(
  fs
    .readdirSync(packagesDir)
    .filter((f) => f.endsWith('.pkg')),
);
if (shipped.size === 0) throw new Error(`no .pkg files in ${packagesDir}`);

/** Walk a directory tree, returning file paths. */
function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}

// module -> package, plus the modules the wasm already provides (base)
const modules = {};
const embedded = [];
for (const file of walk(mapRoot)) {
  if (!file.endsWith('.txt')) continue;
  const rel = path.relative(mapRoot, file);
  const mod = rel.replace(/\\/g, '/').replace(/\.txt$/, '').replace(/\//g, '.');
  const pkg = fs.readFileSync(file, 'utf8').trim();
  if (!pkg) continue;
  if (shipped.has(pkg)) modules[mod] = pkg;
  else if (pkg.startsWith('base-')) embedded.push(mod);
}

// package -> dependencies (only shipped ones; base is embedded)
const packages = {};
for (const line of fs.readFileSync(depsFile, 'utf8').split(/\r?\n/)) {
  if (!line.trim()) continue;
  const [file, depStr = ''] = line.split('|');
  const name = file.trim();
  if (!shipped.has(name)) continue;
  packages[name] = depStr
    .trim()
    .split(/\s+/)
    .filter((d) => d && !d.startsWith('base-'))
    .map((d) => d + '.pkg')
    .filter((d) => shipped.has(d))
    .filter((d, i, a) => a.indexOf(d) === i)
    .sort();
}

// curated: modules the wasm bundle provides beyond the build's maps (the bundle
// embeds canvhs, which is never built as a .pkg), and the modules users expect
// but that cannot be provided here, with a reason.
let support = {};
try {
  support = JSON.parse(fs.readFileSync(supportFile, 'utf8'));
} catch (e) {
  console.warn(`warning: no module-support.json at ${supportFile} (${e.message})`);
}
for (const mod of support.embedded || []) {
  if (!modules[mod] && !embedded.includes(mod)) embedded.push(mod);
}
embedded.sort();
const unavailable = support.unavailable || [];

const out = path.join(pkgDir, 'index.json');
fs.writeFileSync(
  out,
  JSON.stringify({ modules, packages, embedded, unavailable }, null, 2) + '\n',
);

console.log(
  `manifest: ${Object.keys(modules).length} modules, ${Object.keys(packages).length} packages, ` +
    `${embedded.length} embedded, ${unavailable.length} unavailable rules -> ${out}`,
);
for (const p of Object.keys(packages).sort()) {
  console.log(`  ${p} -> ${packages[p].join(', ') || '(none)'}`);
}
