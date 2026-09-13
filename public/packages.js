'use strict';

/**
 * Package manifest handling for lazy loading.
 *
 * The browser bundle embeds `base`; everything else lives in public/pkgs as MicroHs
 * packages (.pkg) plus module maps. Fetching all of them on every boot is wasteful
 * (177 files / ~3 MB), so instead we work out which packages a program actually
 * imports and load only those.
 *
 * Manifest (public/pkgs/index.json):
 *   {
 *     "modules":     { "Data.Map": "containers-0.8.pkg", ... },
 *     "packages":    { "containers-0.8.pkg": ["array-mhs-0.5.8.0.pkg", ...], ... },
 *     "embedded":    ["Data.List", ...],
 *     "unavailable": [ { "prefix": "Data.Aeson", "reason": "not bundled with this playground" } ]
 *   }
 * `embedded` is what the wasm already provides (base), and `unavailable` is the curated
 * set of modules users expect but that cannot be provided here. Together they let the
 * runtime say "not available here, because X" rather than emitting a bare
 * "Module not found" that looks like a broken package.
 * A legacy flat array of file paths is still understood (and disables lazy loading).
 *
 * Package DB layout expected inside the virtual FS (see MicroHs.Package):
 *   /pkgs/packages/<name>.pkg      serialized package
 *   /pkgs/<Module>.txt             contains the package file name
 */

(function () {
  const PKG_BASE = 'pkgs/';
  const MANIFEST_URL = PKG_BASE + 'index.json';

  let manifestPromise = null;

  function loadManifest() {
    if (!manifestPromise) {
      manifestPromise = fetch(MANIFEST_URL, { cache: 'no-store' })
        .then(function (res) {
          return res.ok ? res.json() : null;
        })
        .then(function (m) {
          if (!m) return null;
          // Legacy: a flat list of files means "load everything" (no modules map).
          if (Array.isArray(m)) return { files: m, modules: null, packages: null };
          return m;
        })
        .catch(function () {
          return null;
        });
    }
    return manifestPromise;
  }

  /** Is lazy loading possible with this manifest? */
  function isLazy(manifest) {
    return !!(manifest && manifest.modules && manifest.packages);
  }

  /**
   * Where does a module come from?
   * @returns {{kind:'package'|'embedded'|'unavailable'|'unknown', pkg?:string, reason?:string}}
   */
  function classifyModule(name, manifest) {
    if (!manifest) return { kind: 'unknown' };
    if (manifest.modules && manifest.modules[name]) {
      return { kind: 'package', pkg: manifest.modules[name] };
    }
    if (manifest.embedded && manifest.embedded.indexOf(name) !== -1) {
      return { kind: 'embedded' };
    }
    for (const rule of manifest.unavailable || []) {
      if (name === rule.prefix || name.indexOf(rule.prefix + '.') === 0) {
        return { kind: 'unavailable', reason: rule.reason };
      }
    }
    return { kind: 'unknown' };
  }

  /**
   * Imported module names in a source file, in source order.
   * Comments are removed first: `{- import Data.Aeson -}` or a commented-out import
   * must not be reported as a module we cannot provide.
   */
  function importedModules(source) {
    const code = String(source)
      .replace(/\{-[\s\S]*?-\}/g, ' ')
      .split('\n')
      .map(function (line) {
        return line.replace(/--.*$/, '');
      })
      .join('\n');
    const out = [];
    const re = /^[ \t]*import[ \t]+(?:safe[ \t]+)?(?:qualified[ \t]+)?(?:"[^"]*"[ \t]+)?([A-Z][A-Za-z0-9_.']*)/gm;
    let m;
    while ((m = re.exec(code)) !== null) {
      if (out.indexOf(m[1]) === -1) out.push(m[1]);
    }
    return out;
  }

  /**
   * What a program needs, and what it cannot have.
   * @returns {{packages:string[], missing:{module:string, reason:string}[]}|null}
   */
  function analyzeImports(source, manifest) {
    if (!isLazy(manifest)) return null;

    const needed = new Set();
    const missing = [];
    for (const mod of importedModules(source)) {
      const found = classifyModule(mod, manifest);
      if (found.kind === 'package') needed.add(found.pkg);
      else if (found.kind === 'unavailable') {
        missing.push({ module: mod, reason: found.reason });
      } else if (found.kind === 'unknown') {
        missing.push({ module: mod, reason: 'not bundled with this playground' });
      }
    }

    const closure = new Set();
    const queue = Array.from(needed);
    while (queue.length) {
      const pkg = queue.shift();
      if (closure.has(pkg)) continue;
      closure.add(pkg);
      for (const dep of manifest.packages[pkg] || []) {
        if (!closure.has(dep) && queue.indexOf(dep) === -1) queue.push(dep);
      }
    }
    return { packages: Array.from(closure).sort(), missing: missing };
  }

  /**
   * A human explanation for imports we cannot satisfy, or null if there are none.
   * Deliberately not phrased as a compiler error: the compiler did nothing wrong.
   */
  function explainMissing(missing, manifest) {
    if (!missing || !missing.length) return null;
    const lines = ['Not available in this playground:'];
    for (const item of missing) {
      lines.push('  ' + item.module + ' — ' + item.reason);
    }
    const examples = ['Data.Map', 'Control.Monad.State', 'System.Random', 'Data.Time',
                      'Test.Hspec', 'Test.QuickCheck'].filter(function (mod) {
      return manifest && manifest.modules && manifest.modules[mod] !== undefined;
    });
    const count = manifest && manifest.modules ? Object.keys(manifest.modules).length : 0;
    const base = manifest && manifest.embedded ? manifest.embedded.length : 0;
    const pkgs = manifest && manifest.packages ? Object.keys(manifest.packages).length : 0;
    lines.push('');
    lines.push(
      'This playground provides base (' +
        base +
        ' modules) plus ' +
        pkgs +
        ' packages (' +
        count +
        ' modules), including ' +
        (examples.length ? examples.join(', ') + ', …' : 'see public/pkgs/index.json') +
        '.',
    );
    return lines.join('\n');
  }

  /**
   * Packages required by a program: the packages providing its imported modules,
   * plus their transitive MicroHs dependencies.
   * @returns {string[]|null} package file names, or null if it cannot be determined
   */
  function requiredFor(source, manifest) {
    const analysis = analyzeImports(source, manifest);
    return analysis ? analysis.packages : null;
  }

  /** Modules provided by the given package file names (for synthesising maps). */
  function modulesOf(pkgFiles, manifest) {
    const out = [];
    if (!isLazy(manifest)) return out;
    const wanted = new Set(pkgFiles);
    for (const mod of Object.keys(manifest.modules)) {
      if (wanted.has(manifest.modules[mod])) out.push(mod);
    }
    return out;
  }

  /** Fetch the given package files. @returns {Promise<Object<string, Uint8Array>>} */
  function fetchPackages(pkgFiles) {
    const out = {};
    return Promise.all(
      pkgFiles.map(function (name) {
        return fetch(PKG_BASE + 'packages/' + name, { cache: 'force-cache' })
          .then(function (res) {
            if (!res.ok) return null;
            return res.arrayBuffer().then(function (buf) {
              out[name] = new Uint8Array(buf);
            });
          })
          .catch(function () {
            return null;
          });
      }),
    ).then(function () {
      return out;
    });
  }

  // globalThis so the same file works in a window and in a Worker.
  const api = globalThis.mhsPackages || {};
  api.loadManifest = loadManifest;
  api.isLazy = isLazy;
  api.classifyModule = classifyModule;
  api.importedModules = importedModules;
  api.analyzeImports = analyzeImports;
  api.explainMissing = explainMissing;
  api.requiredFor = requiredFor;
  api.modulesOf = modulesOf;
  api.fetchPackages = fetchPackages;
  api.PKG_BASE = PKG_BASE;
  globalThis.mhsPackages = api;
})();
