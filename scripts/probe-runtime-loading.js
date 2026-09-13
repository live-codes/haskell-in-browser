'use strict';

/**
 * Runtime module-loading probes.
 *
 * These assert *interpreter* behaviour rather than the runner contract
 * (program in -> {output, error, exitCode} out), so they drive `startRepl`
 * directly: each scenario needs its own compiler flags and writes files into the
 * virtual FS mid-session. See FINDINGS.md, "Correction (verified)".
 *
 *   1. source-unpathed  - a .hs file off the source path is not found; the default
 *                         source path is ["."] (the cwd, /home/web_user).
 *   2. source-pathed    - the same file compiles once its directory is on -i.
 *   3. source-dynamic   - nested source trees resolve, and a module written *after*
 *                         boot compiles on demand: the source path is live.
 *   4. late-package     - a .pkg plus its module maps written after boot are picked
 *                         up at import time, so no reload is needed as long as
 *                         -a/pkgs was passed (even with an empty directory).
 *
 * Each scenario runs in its own process, because argv and the virtual FS are
 * per-boot. Boot is a few seconds per scenario.
 *
 *   node scripts/probe-runtime-loading.js            # all scenarios
 *   node scripts/probe-runtime-loading.js --scenario late-package
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const { startRepl } = require('./node-repl-run.js');

const HOME = '/home/web_user';
const PKG_DIR = '/pkgs';
const PUBLIC = path.join(__dirname, '..', 'public');

const MYLIB = [
  'module MyLib (greet) where',
  '',
  'greet :: String -> String',
  'greet who = "hello, " ++ who',
  '',
].join('\n');

const MAIN_MYLIB = [
  'import MyLib',
  '',
  'main :: IO ()',
  'main = putStrLn (greet "world")',
  '',
].join('\n');

const BAR = ['module Foo.Bar (twice) where', '', 'twice :: Int -> Int', 'twice n = n * 2', ''].join('\n');
const LATE = ['module Late (answer) where', '', 'answer :: Int', 'answer = 42', ''].join('\n');

const PRETTY_PKG = 'pretty-1.1.3.6.pkg';
const MAIN_PRETTY = [
  'import Text.PrettyPrint',
  '',
  'main :: IO ()',
  'main = putStrLn (render (text "hi"))',
  '',
].join('\n');

/** Same shape as node-repl-run.js: failures are reported, not thrown. */
function looksLikeError(text) {
  return /Module not found|Exception|error:/.test(text || '');
}

function check(name, ok, detail) {
  return { name: name, ok: !!ok, detail: String(detail == null ? '' : detail).split('\n')[0] };
}

/** Modules provided by a package, as DB-relative map paths ("Text/PrettyPrint.txt"). */
function mapsFor(pkgFile) {
  const manifest = JSON.parse(fs.readFileSync(path.join(PUBLIC, 'pkgs', 'index.json'), 'utf8'));
  return Object.keys(manifest.modules)
    .filter(function (mod) {
      return manifest.modules[mod] === pkgFile;
    })
    .map(function (mod) {
      return mod.replace(/\./g, '/') + '.txt';
    });
}

const scenarios = {
  /** Control: a source module outside the search path must not be found. */
  'source-unpathed': async function () {
    const s = await startRepl({
      files: { [HOME + '/lib/MyLib.hs']: MYLIB, [HOME + '/Main.hs']: MAIN_MYLIB },
    });
    const out = await s.step('import Main');
    return [
      check(
        'module off the source path is not found',
        /Module not found: MyLib/.test(out),
        out,
      ),
    ];
  },

  /** -i puts the directory on the source path, so the module compiles. */
  'source-pathed': async function () {
    const s = await startRepl({
      args: ['-i' + HOME + '/lib'],
      files: { [HOME + '/lib/MyLib.hs']: MYLIB, [HOME + '/Main.hs']: MAIN_MYLIB },
    });
    const imported = await s.step('import Main');
    const out = await s.step(':main');
    return [
      check('import succeeds with -i', !looksLikeError(imported), imported),
      check('program runs against the source module', /hello, world/.test(out), out),
    ];
  },

  /**
   * The source path is live: files present at boot resolve (including nested
   * module trees), and a module written later compiles with no reload.
   */
  'source-dynamic': async function () {
    const s = await startRepl({
      files: { [HOME + '/Foo/Bar.hs']: BAR, [HOME + '/Main.hs']: 'main = pure ()\n' },
    });
    const nested = await s.step('import Foo.Bar');
    const value = await s.step('twice 21');

    s.m.FS.writeFile(HOME + '/Late.hs', LATE);
    const late = await s.step('import Late');
    const lateValue = await s.step('answer');

    return [
      check('nested source module resolves at boot', !looksLikeError(nested), nested),
      check('nested module evaluates', /\b42\b/.test(value), value),
      check('module written after boot imports (no reload)', !looksLikeError(late), late),
      check('post-boot module evaluates', /\b42\b/.test(lateValue), lateValue),
    ];
  },

  /**
   * The package path only has to *exist* at boot; the files can arrive later.
   * `pretty` is the fixture because it depends on base alone (embedded), so no
   * dependency closure is involved.
   */
  'late-package': async function () {
    const s = await startRepl({
      args: ['-a' + PKG_DIR],
      files: { [HOME + '/Main.hs']: MAIN_PRETTY },
    });

    const before = await s.step('import Text.PrettyPrint');

    const FS = s.m.FS;
    const maps = mapsFor(PRETTY_PKG);
    FS.mkdirTree(PKG_DIR + '/packages');
    FS.writeFile(PKG_DIR + '/packages/' + PRETTY_PKG, fs.readFileSync(path.join(PUBLIC, 'pkgs', 'packages', PRETTY_PKG)));
    for (const rel of maps) {
      const dir = PKG_DIR + '/' + rel.slice(0, rel.lastIndexOf('/'));
      FS.mkdirTree(dir);
      FS.writeFile(PKG_DIR + '/' + rel, PRETTY_PKG);
    }

    const after = await s.step('import Text.PrettyPrint');
    const imported = await s.step('import Main');
    const out = await s.step(':main');

    return [
      check('import fails while the package is absent', /Module not found/.test(before), before),
      check(
        'wrote the .pkg and its ' + maps.length + ' module maps after boot',
        maps.length > 0,
        maps.join(', '),
      ),
      check('same import succeeds with no reload', !looksLikeError(after), after),
      check('program using the package runs', /^hi$/m.test(out), out || imported),
    ];
  },
};

async function runOne(name) {
  const checks = await scenarios[name]();
  return { scenario: name, checks: checks };
}

if (require.main === module) {
  const argv = process.argv.slice(2);
  const at = argv.indexOf('--scenario');

  if (at !== -1) {
    const name = argv[at + 1];
    if (!scenarios[name]) {
      console.log(JSON.stringify({ scenario: name, checks: [], error: 'unknown scenario' }));
      process.exit(1);
    }
    runOne(name)
      .then(function (res) {
        console.log(JSON.stringify(res));
        process.exit(0);
      })
      .catch(function (err) {
        console.log(
          JSON.stringify({ scenario: name, checks: [], error: String((err && err.message) || err) }),
        );
        process.exit(1);
      });
  } else {
    let pass = 0;
    let fail = 0;
    for (const name of Object.keys(scenarios)) {
      const t0 = Date.now();
      const proc = spawnSync(process.execPath, [__filename, '--scenario', name], {
        encoding: 'utf8',
        timeout: 240000,
      });

      let res;
      try {
        res = JSON.parse(proc.stdout.trim().split('\n').pop());
      } catch (err) {
        res = { checks: [], error: 'unparseable output: ' + proc.stdout + proc.stderr };
      }

      const ok = !res.error && res.checks.length > 0 && res.checks.every((c) => c.ok);
      if (ok) pass++;
      else fail++;

      console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + '  (' + (Date.now() - t0) + ' ms)');
      for (const c of res.checks || []) {
        console.log('      ' + (c.ok ? 'ok  ' : 'FAIL') + '  ' + c.name + (c.detail ? '  -- ' + c.detail : ''));
      }
      if (res.error) console.log('      error: ' + res.error);
    }

    console.log('\n' + pass + ' passed, ' + fail + ' failed');
    process.exit(fail === 0 ? 0 : 1);
  }
}
