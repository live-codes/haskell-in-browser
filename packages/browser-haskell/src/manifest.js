/**
 * Which packages does a program need, and where do they come from?
 *
 * The wasm bundle embeds MicroHs's `base` (+ canvhs). Everything else ships as MicroHs
 * packages, described by a manifest that is fetched lazily and used to pull in only the
 * `.pkg` files a program actually imports:
 *
 *   {
 *     "modules":     { "Data.Map": "containers-0.8.pkg", ... },
 *     "packages":    { "containers-0.8.pkg": ["array-mhs-0.5.8.0.pkg"], ... },
 *     "embedded":    ["Data.List", ...],
 *     "unavailable": [{ "prefix": "Data.Aeson", "reason": "not bundled here" }]
 *   }
 *
 * `embedded` and `unavailable` are what let an import we cannot satisfy come back with
 * "not available, because X" instead of a bare `Module not found`.
 *
 * Inside the compiler's virtual FS the layout is:
 *   /pkgs/packages/<name>.pkg   the serialized package
 *   /pkgs/<Module/Path>.txt     contains the package file name
 */

const withSlash = (url) => (url.endsWith('/') ? url : url + '/');

/** Imported module names in a source file, in source order. Comments are ignored. */
export function importedModules(source) {
  const code = String(source)
    .replace(/\{-[\s\S]*?-\}/g, ' ')
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
  const out = [];
  const re = /^[ \t]*import[ \t]+(?:safe[ \t]+)?(?:qualified[ \t]+)?(?:"[^"]*"[ \t]+)?([A-Z][A-Za-z0-9_.']*)/gm;
  let m;
  while ((m = re.exec(code)) !== null) {
    if (out.indexOf(m[1]) === -1) out.push(m[1]);
  }
  return out;
}

/** The package file name implied by a custom package URL. */
function customName(url) {
  const clean = String(url).split('?')[0].split('#')[0];
  const last = clean.slice(clean.lastIndexOf('/') + 1);
  return last || 'custom.pkg';
}

/**
 * @param {object} options
 * @param {string} options.packagesUrl directory holding index.json and packages/
 * @param {Object<string,string>} [options.importmap] module -> .pkg URL, for packages
 *   that are not in the manifest. They must be built by the same MicroHs version, and
 *   any MicroHs dependencies they have must be mapped here too (the manifest cannot
 *   know about them).
 * @param {(msg: string) => void} [options.log]
 * @param {typeof fetch} [options.fetch]
 */
export function createPackageResolver(options) {
  const opts = options || {};
  const base = withSlash(opts.packagesUrl);
  const importmap = opts.importmap || {};
  const log = opts.log || (() => {});
  const doFetch = opts.fetch || ((...args) => fetch(...args));

  /** module file name -> { name, url, modules } for importmap entries */
  const custom = new Map();
  for (const moduleName of Object.keys(importmap)) {
    const url = importmap[moduleName];
    if (typeof url !== 'string' || !url) continue;
    const name = customName(url);
    const entry = custom.get(name) || { name, url, modules: new Set() };
    entry.modules.add(moduleName);
    custom.set(name, entry);
  }

  let manifestPromise = null;
  let manifest = null;

  function loadManifest() {
    if (!manifestPromise) {
      const url = base + 'index.json';
      manifestPromise = doFetch(url, { cache: 'no-store' })
        .then((res) => (res.ok ? res.json() : null))
        .then((m) => {
          if (!m || Array.isArray(m)) {
            log('no package manifest at ' + url + '; only the embedded modules are available');
            return null;
          }
          manifest = m;
          return m;
        })
        .catch((err) => {
          log('failed to load ' + url + ': ' + (err && err.message));
          return null;
        });
    }
    return manifestPromise;
  }

  /**
   * @returns {{kind:'package'|'custom'|'embedded'|'unavailable'|'unknown', pkg?:string, url?:string, reason?:string}}
   */
  function classifyModule(name) {
    if (custom.has(name)) {
      const entry = custom.get(name);
      return { kind: 'package', pkg: entry.name, url: entry.url };
    }
    if (manifest && manifest.modules && manifest.modules[name]) {
      return { kind: 'package', pkg: manifest.modules[name] };
    }
    if (!manifest) {
      // Without a manifest only the embedded modules are known for sure.
      return { kind: 'unknown' };
    }
    if (manifest.embedded && manifest.embedded.indexOf(name) !== -1) return { kind: 'embedded' };
    for (const rule of manifest.unavailable || []) {
      if (name === rule.prefix || name.indexOf(rule.prefix + '.') === 0) {
        return { kind: 'unavailable', reason: rule.reason };
      }
    }
    return { kind: 'unknown' };
  }

  /**
   * What a program needs before it can compile.
   * @returns {{packages:string[], missing:{module:string, reason:string}[], urls:Object<string,string>}}
   */
  function analyzeImports(source) {
    const needed = new Set();
    const urls = {};
    const missing = [];

    for (const mod of importedModules(source)) {
      if (importmap[mod]) {
        const name = customName(importmap[mod]);
        needed.add(name);
        urls[name] = importmap[mod];
        continue;
      }
      const found = classifyModule(mod);
      if (found.kind === 'package') needed.add(found.pkg);
      else if (found.kind === 'unavailable') missing.push({ module: mod, reason: found.reason });
      else if (found.kind === 'unknown') {
        missing.push({ module: mod, reason: 'not bundled with this playground' });
      }
    }

    // A package brings its MicroHs dependencies with it.
    const closure = new Set();
    const queue = Array.from(needed);
    while (queue.length) {
      const pkg = queue.shift();
      if (closure.has(pkg)) continue;
      closure.add(pkg);
      const deps = (manifest && manifest.packages && manifest.packages[pkg]) || [];
      for (const dep of deps) {
        if (!closure.has(dep) && queue.indexOf(dep) === -1) queue.push(dep);
      }
    }

    return { packages: Array.from(closure).sort(), missing, urls };
  }

  /** The package file that provides a module (from the manifest or the importmap). */
  function packageOfModule(mod) {
    if (custom.has(mod)) return custom.get(mod).name;
    if (manifest && manifest.modules) return manifest.modules[mod] || null;
    return null;
  }

  /** Modules provided by the given package files (used to write the lookup maps). */
  function modulesOf(pkgFiles) {
    const out = [];
    const wanted = new Set(pkgFiles);
    if (manifest && manifest.modules) {
      for (const mod of Object.keys(manifest.modules)) {
        if (wanted.has(manifest.modules[mod])) out.push(mod);
      }
    }
    for (const entry of custom.values()) {
      if (wanted.has(entry.name)) out.push(...entry.modules);
    }
    return out;
  }

  /** Fetch package files. @returns {Promise<Object<string, Uint8Array>>} */
  function fetchPackages(names, urls) {
    const out = {};
    return Promise.all(
      names.map((name) => {
        const url = (urls && urls[name]) || base + 'packages/' + name;
        return doFetch(url, { cache: 'force-cache' })
          .then((res) => {
            if (!res.ok) throw new Error('HTTP ' + res.status + ' for ' + url);
            return res.arrayBuffer();
          })
          .then((buf) => {
            out[name] = new Uint8Array(buf);
          })
          .catch((err) => {
            log('could not fetch ' + url + ': ' + (err && err.message));
          });
      }),
    ).then(() => out);
  }

  /** A human explanation for imports we cannot satisfy, or null if there are none. */
  function explainMissing(missing) {
    if (!missing || !missing.length) return null;
    const lines = ['Not available in this playground:'];
    for (const item of missing) lines.push('  ' + item.module + ' — ' + item.reason);
    if (manifest && manifest.modules && manifest.packages) {
      const count = Object.keys(manifest.modules).length;
      const base = (manifest.embedded || []).length;
      const pkgs = Object.keys(manifest.packages).length;
      const examples = ['Data.Map', 'Control.Monad.State', 'System.Random', 'Data.Time', 'Test.Hspec']
        .filter((mod) => manifest.modules[mod] !== undefined);
      lines.push('');
      lines.push(
        'This playground provides ' + base + ' built-in modules plus ' + pkgs + ' packages (' + count +
          ' modules), including ' + (examples.length ? examples.join(', ') + ', …' : 'see the manifest') + '.',
      );
    }
    return lines.join('\n');
  }

  /**
   * The backstop for a `Module not found: X` the pre-check could not see — the reason
   * is appended so the message does not look like a broken package.
   */
  function explainNotFound(text) {
    if (!text) return text;
    const seen = [];
    const re = /Module not found:\s*([A-Z][A-Za-z0-9_.']*)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const name = m[1];
      if (seen.some((s) => s.module === name)) continue;
      const found = classifyModule(name);
      if (found.kind === 'unavailable') seen.push({ module: name, reason: found.reason });
      else if (found.kind === 'unknown') seen.push({ module: name, reason: 'not bundled with this playground' });
      else if (found.kind === 'package') {
        seen.push({ module: name, reason: 'its package (' + found.pkg + ') is not loaded' });
      }
    }
    const why = explainMissing(seen);
    return why ? text + '\n\n' + why : text;
  }

  return {
    loadManifest,
    classifyModule,
    analyzeImports,
    packageOfModule,
    modulesOf,
    fetchPackages,
    explainMissing,
    explainNotFound,
    get manifest() {
      return manifest;
    },
  };
}
