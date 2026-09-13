'use strict';

/**
 * Drive the MicroHs interactive REPL.
 *
 * The published bundle cannot compile-and-run in batch mode (`-r`/`-e` are
 * inert: `compiledWithMhs` is false), so the REPL is the only execution path.
 * Protocol (mirrors web-mhs, verified empirically):
 *   - input is delivered with Module._set_input_char, interleaved with the loop,
 *   - `.mhsi_rc` sets a sentinel prompt so completion is detectable,
 *   - a program runs via `import Main` -> `:reload` -> `:main`,
 *   - the REPL echoes typed input, so echoed lines are stripped.
 *
 * CLI:
 *   node node-repl-run.js --file Main.hs [--dump]
 *   node node-repl-run.js --mode eval --expr 'map (+1) [1..5]'
 *   node node-repl-run.js --probe-imports Data.Map,Data.Set,control...
 */

const path = require('path');

const MHS_DIR = path.join(__dirname, '..', 'public', 'mhs');
const MHS_JS = path.join(MHS_DIR, 'mhs-embed.js');
const HOME = '/home/web_user';
const PROMPT = '<<<LC_PROMPT>>>';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const decoder = new TextDecoder('utf-8', { fatal: false });

function countOccurrences(hay, needle) {
  let n = 0;
  let i = 0;
  while ((i = hay.indexOf(needle, i)) !== -1) {
    n++;
    i += needle.length;
  }
  return n;
}

/** Strip prompts, ANSI escapes, echoed input and the startup banner. */
function clean(text, sentLines) {
  const banner = [
    /^Welcome to interactive MicroHs/,
    /^Integer implemented with imath/,
    /^Loading embedded package /,
    /^Loading package /,
    /^Type ':quit' to quit/,
    /^loaded /,
  ];
  return text
    .split(PROMPT)
    .join('')
    .replace(/^> ?/gm, '')
    .split('\n')
    .filter((line) => {
      const t = line.trim();
      if (banner.some((re) => re.test(t))) return false;
      if (sentLines.some((s) => t === s)) return false;
      return true;
    })
    .join('\n');
}

/** Split REPL chatter into program output and error lines. */
function classify(text) {
  const errorLines = [];
  const outLines = [];
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (
      /^(\*\*\* )?(Exception|error:|Error:)/.test(t) ||
      /^Unrecognized command/.test(t) ||
      /: line \d+, col \d+:/.test(t) ||
      /^\d+:\d+:/.test(t)
    ) {
      errorLines.push(line);
    } else {
      outLines.push(line);
    }
  }
  return {
    output: outLines.join('\n').trim() ? outLines.join('\n') : null,
    error: errorLines.length ? errorLines.join('\n') : null,
  };
}

/** Boot the REPL and return a session handle. */
async function startRepl(opts) {
  const options = opts || {};
  const charDelay = options.charDelay == null ? 2 : options.charDelay;
  const stepTimeout = options.timeout || 60000;

  // No module args => REPL. Callers may pass extra compiler flags (e.g. -i<dir>).
  process.argv = [process.argv[0], process.argv[1]].concat(options.args || []);

  const state = { raw: '', exited: false, exitCode: null };

  delete require.cache[require.resolve(MHS_JS)];
  const m = require(MHS_JS);

  m.locateFile = (p) => path.join(MHS_DIR, p);
  // fd 0 returns EOF: program stdin is not usable, so input is provided through
  // the stdin shim instead (see runRepl).
  m.stdin = () => null;
  m.stdout = (code) => code !== null && (state.raw += String.fromCharCode(code));
  m.stderr = (code) => code !== null && (state.raw += String.fromCharCode(code));
  m.print = (text) => (state.raw += String(text) + '\n');
  m.printErr = (text) => (state.raw += String(text) + '\n');
  m.onExit = (code) => {
    state.exited = true;
    state.exitCode = code;
  };
  m.preRun = [
    () => {
      const FS = m.FS;
      FS.mkdirTree(HOME);
      FS.chdir(HOME);
      FS.writeFile('.mhsi_rc', ':set prompt=' + PROMPT + '\n');
      FS.writeFile('Main.hs', '');
      // Extra files for the virtual FS, keyed by absolute path: lets a caller set
      // up a source tree or a package directory before the compiler starts.
      for (const p of Object.keys(options.files || {})) {
        const dir = p.slice(0, p.lastIndexOf('/'));
        if (dir) FS.mkdirTree(dir);
        FS.writeFile(p, options.files[p]);
      }
    },
  ];

  const promptCount = () => countOccurrences(state.raw, PROMPT);

  async function waitFor(target, label) {
    const t0 = Date.now();
    while (Date.now() - t0 < stepTimeout) {
      if (state.exited) return;
      if (promptCount() >= target) return;
      await sleep(15);
    }
    throw new Error('timeout waiting for ' + label);
  }

  async function typeLine(text) {
    const bytes = new TextEncoder().encode(text + '\n');
    for (const b of bytes) {
      m._set_input_char(b);
      if (charDelay) await sleep(charDelay);
    }
  }

  /** Type a line and return the cleaned output produced for it. */
  async function step(line) {
    const baseline = promptCount();
    const mark = state.raw.length;
    await typeLine(line);
    await waitFor(baseline + 1, JSON.stringify(line));
    return clean(state.raw.slice(mark), [line]);
  }

  await waitFor(1, 'first prompt');

  return { state, m, promptCount, waitFor, typeLine, step, clean, classify };
}

/** Escape a string as a Haskell string literal. */
function toHaskellString(text) {
  return String(text)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/\r/g, '\\r')
    .replace(/\t/g, '\\t');
}

/**
 * Program stdin is not wired in this build (System.IO reads fd 0, which is EOF),
 * so expose the input as pure bindings the program can use. Appended to the
 * user's module: order-independent in Haskell and needs no imports.
 */
function stdinShim(input) {
  return [
    '',
    '-- stdin shim: this build cannot read stdin at the system level',
    'lcInput :: String',
    'lcInput = "' + toHaskellString(input) + '"',
    '',
    'lcInputLines :: [String]',
    'lcInputLines = lines lcInput',
    '',
    'lcInputWords :: [String]',
    'lcInputWords = words lcInput',
    '',
  ].join('\n');
}

async function runRepl(options) {
  const opts = options || {};
  const input = opts.stdin == null ? '' : String(opts.stdin);
  const source = String(opts.source || '') + (input ? stdinShim(input) : '');
  const s = await startRepl(opts);

  let cleaned;
  let importOut = '';
  let reloadOut = '';
  if (opts.mode === 'eval') {
    cleaned = await s.step(String(opts.expr || ''));
  } else {
    s.m.FS.writeFile('Main.hs', source);
    // Compilation is triggered by `import Main`; which step reports a diagnostic
    // depends on whether Main was already loaded, so check both (not concatenated,
    // to avoid duplicating the same message).
    importOut = await s.step('import Main');
    // The REPL caches modules; :reload recompiles from source.
    reloadOut = await s.step(':reload');
    cleaned = await s.step(':main');
  }

  const mainRes = classify(cleaned);
  const cImport = classify(importOut);
  const cReload = classify(reloadOut);
  const compileRaw = importOut.trim() ? importOut : reloadOut;
  // A compile failure is reported before :main, which only says
  // "undefined value: main".
  const finalError =
    cImport.error || cReload.error || (compileRaw.trim() ? compileRaw.trim() : null) || mainRes.error;

  return {
    output: mainRes.output,
    error: finalError,
    exitCode: s.state.exitCode == null ? 0 : s.state.exitCode,
    raw: opts.dump ? s.state.raw : undefined,
    exited: s.state.exited,
  };
}

/**
 * Report which modules resolve in this bundle.
 * @param {string[]} modules
 */
async function probeImports(modules) {
  const s = await startRepl({});
  const results = [];
  for (const name of modules) {
    const out = await s.step('import ' + name);
    // Embedded-package modules import silently; only failures print a message.
    const failed = /Module not found|Exception|error:/.test(out);
    results.push({
      module: name,
      ok: !failed,
      detail: failed ? out.replace(/^\s+|\s+$/g, '').split('\n')[0] : '',
    });
  }
  return results;
}

module.exports = { runRepl, probeImports, startRepl, PROMPT };

if (require.main === module) {
  const a = process.argv.slice(2);
  const args = { file: null, timeout: 60000, dump: false, mode: 'run', expr: '', probe: null, stdin: '' };
  for (let i = 0; i < a.length; i++) {
    if (a[i] === '--file') args.file = a[++i];
    else if (a[i] === '--timeout') args.timeout = Number(a[++i]);
    else if (a[i] === '--dump') args.dump = true;
    else if (a[i] === '--mode') args.mode = a[++i];
    else if (a[i] === '--expr') args.expr = a[++i];
    else if (a[i] === '--stdin') args.stdin = a[++i];
    else if (a[i] === '--probe-imports') args.probe = a[++i].split(',').filter(Boolean);
  }

  const done = args.probe
    ? probeImports(args.probe).then((results) => {
        for (const r of results) {
          console.log((r.ok ? 'OK   ' : 'MISS ') + r.module + (r.detail ? '   ' + r.detail : ''));
        }
        const ok = results.filter((r) => r.ok).length;
        console.log(`\n${ok}/${results.length} modules available`);
      })
    : (() => {
        const fs = require('fs');
        const source = args.file ? fs.readFileSync(args.file, 'utf8') : '';
        return runRepl({
          source,
          timeout: args.timeout,
          dump: args.dump,
          mode: args.mode,
          expr: args.expr,
          stdin: args.stdin,
        }).then((r) => {
          process.stdout.write(JSON.stringify(r) + '\n');
        });
      })();

  done
    .then(() => process.exit(0))
    .catch((err) => {
      process.stdout.write(JSON.stringify({ error: String(err && err.message) }) + '\n');
      process.exit(1);
    });
}
