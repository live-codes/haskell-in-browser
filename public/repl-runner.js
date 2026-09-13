'use strict';

/**
 * MicroHs REPL driver.
 *
 * The published `mhs-embed` bundle cannot compile-and-run in batch mode
 * (see ../FINDINGS.md), so the only execution path is the interactive REPL.
 * This mirrors how web-mhs drives it:
 *   - configure the Emscripten Module the same way (FS.init with char callbacks,
 *     push input via Module._set_input_char),
 *   - set a sentinel prompt via .mhsi_rc so completion is detectable,
 *   - "type" commands and read the output between prompts.
 *
 * One REPL instance per page load; it is a persistent process.
 * Call `send(line)` from the console to drive it by hand.
 */

const HOME = '/home/web_user';
const MAIN_FILE = 'Main.hs';
const PROMPT = '<<<LC_PROMPT>>>';
const PKG_DIR = '/pkgs';
const PERSIST_KEY = 'mhs.packages';

// Program output arrives as UTF-8 bytes, one char code at a time; a streaming
// decoder keeps multi-byte characters (e.g. hspec's check mark) intact.
const outDecoder = new TextDecoder('utf-8', { fatal: false });
function appendCode(code) {
  state.raw += outDecoder.decode(new Uint8Array([code]), { stream: true });
}

const state = {
  raw: '',
  ready: false,
  running: false,
  exited: false,
  exitCode: null,
  fatal: null,
  module: null,
  manifest: null,
  /** Package file names currently written into the virtual FS. */
  loaded: [],
  files: {},
};

/** Packages persisted from a previous run (monotonic, so switching programs does not thrash). */
function persistedPackages() {
  try {
    const raw = localStorage.getItem(PERSIST_KEY);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list : [];
  } catch (err) {
    return [];
  }
}

function persistPackages(list) {
  try {
    localStorage.setItem(PERSIST_KEY, JSON.stringify(list));
  } catch (err) {
    /* storage unavailable: lazy loading simply re-resolves each session */
  }
}

/**
 * Decide which package files to load for this session.
 * Lazy (manifest has modules+packages): only what has been requested so far.
 * Legacy flat file list: everything, as before.
 * @returns {Promise<{files: Object<string, Uint8Array>, names: string[]}>}
 */
async function collectPackages() {
  state.manifest = await window.mhsPackages.loadManifest();
  const manifest = state.manifest;

  if (!manifest) return { files: {}, names: [] };

  if (!window.mhsPackages.isLazy(manifest)) {
    const out = {};
    await Promise.all(
      (manifest.files || []).map(async (rel) => {
        const res = await fetch('pkgs/' + rel, { cache: 'force-cache' });
        if (res.ok) out[rel] = new Uint8Array(await res.arrayBuffer());
      }),
    );
    emit('log', 'loaded ' + Object.keys(out).length + ' package file(s) (eager)');
    return { files: out, names: [] };
  }

  const names = persistedPackages();
  const bytes = await window.mhsPackages.fetchPackages(names);
  const files = {};
  for (const name of Object.keys(bytes)) files['packages/' + name] = bytes[name];
  const got = Object.keys(bytes);
  emit('log', 'loaded ' + got.length + ' package(s) on demand: ' + (got.join(', ') || 'none'));
  return { files, names: got };
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
 * so provide the input as pure bindings the program can use. Appended to the end
 * of the user's module, which is order-independent in Haskell and needs no imports.
 */
function stdinShim(input) {
  const lit = toHaskellString(input);
  return [
    '',
    '-- stdin shim (LiveCodes): this build cannot read stdin at the system level',
    'lcInput :: String',
    'lcInput = "' + lit + '"',
    '',
    'lcInputLines :: [String]',
    'lcInputLines = lines lcInput',
    '',
    'lcInputWords :: [String]',
    'lcInputWords = words lcInput',
    '',
  ].join('\n');
}

const listeners = { log: [], exit: [] };

function on(kind, fn) {
  (listeners[kind] = listeners[kind] || []).push(fn);
}

function emit(kind, value) {
  for (const fn of listeners[kind] || []) fn(value);
}

function log(...args) {
  emit('log', args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' '));
}

function promptCount() {
  let n = 0;
  let i = 0;
  while ((i = state.raw.indexOf(PROMPT, i)) !== -1) {
    n++;
    i += PROMPT.length;
  }
  return n;
}

function waitUntil(predicate, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    const t0 = performance.now();
    const tick = () => {
      if (predicate()) return resolve();
      if (!state.running && state.exited) return reject(new Error('REPL exited while waiting for ' + label));
      if (state.exited) return reject(new Error('REPL exited while waiting for ' + label));
      if (performance.now() - t0 > timeoutMs) return reject(new Error('Timed out waiting for ' + label));
      requestAnimationFrame(tick);
    };
    tick();
  });
}

/** Type a line into the REPL one char at a time, yielding between chars. */
async function typeLine(text) {
  const bytes = new TextEncoder().encode(text + '\n');
  for (const b of bytes) {
    state.module._set_input_char(b);
    await new Promise((r) => setTimeout(r, 0));
  }
}

/** Apply backspaces the way a terminal would (delete the previous character). */
function applyBackspaces(text) {
  let out = '';
  for (const ch of text) {
    if (ch === '\b') out = out.slice(0, -1);
    else out += ch;
  }
  return out;
}

/**
 * Collapse carriage-return overwrites: progress lines like "adds [ ]\radds [x]"
 * should keep only the final state, as a terminal would show.
 */
function applyCarriageReturns(text) {
  return text
    .split('\n')
    .map((line) => {
      const i = line.lastIndexOf('\r');
      return i >= 0 ? line.slice(i + 1) : line;
    })
    .join('\n');
}

/** Remove prompts, ANSI escapes, echoed input lines and the startup banner. */
function clean(text, sentLines) {
  const noPrompts = text.split(PROMPT).join('');
  // Strip ANSI/VT control sequences (hspec uses cursor control) — they cannot
  // render in a <pre>, and they would also confuse output comparison.
  const noAnsi = applyCarriageReturns(
    applyBackspaces(
      noPrompts
        // eslint-disable-next-line no-control-regex
        .replace(/\u001b\[[0-9;?]*[A-Za-z]|\u001b[@-Z\\-_]|\u001b\([A-Za-z0-9]/g, '')
        .replace(/\u0007/g, ''),
    ),
  );
  const banner = [
    /^Welcome to interactive MicroHs/,
    /^Integer implemented with imath/,
    /^Loading embedded package /,
    /^Loading package /,
    /^loaded /,
    /^Type ':quit' to quit/,
  ];
  return noAnsi
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
      /: line \d+, col \d+:/.test(t)
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

/** Boot the Emscripten module; resolves when the first prompt is seen. */
async function boot() {
  const collected = await collectPackages();
  state.files = collected.files;
  state.loaded = collected.names;
  const hasPackages = Object.keys(state.files).length > 0;
  // `-aPATH` appends to the package search path, so packages written into the
  // virtual FS become importable.
  const args = hasPackages ? ['-a' + PKG_DIR] : [];

  return new Promise((resolve, reject) => {
    const rc = ':set prompt=' + PROMPT + '\n';
    const lazy = window.mhsPackages.isLazy(state.manifest);

    const Module = {
      arguments: args,
      locateFile: (p) => 'mhs/' + p,
      preRun: [
        function () {
          Module.FS.mkdirTree(HOME);
          Module.FS.chdir(HOME);
          Module.FS.writeFile('.mhsi_rc', rc);
          Module.FS.writeFile(MAIN_FILE, '');
          // Package files (relative paths already match the DB layout).
          for (const rel of Object.keys(state.files)) {
            const parts = rel.split('/');
            const file = parts.pop();
            const dir = PKG_DIR + (parts.length ? '/' + parts.join('/') : '');
            Module.FS.mkdirTree(dir);
            Module.FS.writeFile(dir + '/' + file, state.files[rel]);
          }
          // Module -> package maps. With lazy loading these are synthesised from the
          // manifest for the loaded packages, so they are never fetched individually.
          if (lazy) {
            for (const mod of window.mhsPackages.modulesOf(state.loaded, state.manifest)) {
              const path = PKG_DIR + '/' + mod.replace(/\./g, '/') + '.txt';
              const dir = path.slice(0, path.lastIndexOf('/'));
              Module.FS.mkdirTree(dir);
              Module.FS.writeFile(path, state.manifest.modules[mod]);
            }
          }
        },
      ],
      // initRuntime() calls FS.init() with no arguments, which takes these.
      // Input never uses fd 0: it is delivered with _set_input_char.
      stdin: () => null,
      stdout: (code) => code !== null && appendCode(code),
      stderr: (code) => code !== null && appendCode(code),
      print: (text) => {
        state.raw += String(text) + '\n';
      },
      printErr: (text) => {
        state.raw += String(text) + '\n';
      },
      onExit: (code) => {
        state.exited = true;
        state.exitCode = code;
        log('[onExit] ' + code);
        emit('exit', code);
      },
      onAbort: (what) => {
        state.fatal = String(what);
        log('[onAbort] ' + what);
      },
    };

    window.Module = Module;
    state.module = Module;

    const script = document.createElement('script');
    script.src = 'mhs/mhs-embed.js';
    script.onload = () => {
      log('mhs-embed.js loaded; waiting for first prompt');
      waitUntil(() => promptCount() > 0, 20000, 'first prompt')
        .then(() => {
          state.ready = true;
          log('REPL ready');
          resolve();
        })
        .catch(reject);
    };
    script.onerror = () => reject(new Error('failed to load mhs/ mhs-embed.js'));
    document.body.appendChild(script);
  });
}

/**
 * @param {{source: string}} options
 * @returns {Promise<{output: string|null, error: string|null, exitCode: number, raw: string}>}
 */
async function runHaskell(options) {
  const opts = options || {};

  // Lazy loading: if the program imports modules from packages that are not in this
  // session, ask the caller to reload with them (the package path is fixed at boot).
  const needed = window.mhsPackages.requiredFor(String(opts.source || ''), state.manifest);
  if (needed && !hasPackages(needed)) {
    requestPackages(needed);
    return { output: null, error: null, exitCode: 0, needsPackages: needed, reload: true };
  }

  if (!state.ready) throw new Error('REPL is not ready');
  if (state.running) throw new Error('a run is already in progress');
  if (state.exited) throw new Error('REPL already exited; reload the page');

  state.running = true;
  const input = opts.input == null ? '' : String(opts.input);
  // Program stdin is unavailable in this build, so expose it as pure bindings.
  const source = String(opts.source || '') + (input ? stdinShim(input) : '');
  const expr = String(opts.expr || '');

  try {
    const sent = [];
    let baseline = promptCount();
    let mark;
    let importOut = '';
    let reloadOut = '';

    if (opts.mode === 'eval') {
      sent.push(expr);
      mark = state.raw.length;
      await typeLine(expr);
      await waitUntil(() => promptCount() > baseline, 30000, 'expression');
    } else {
      state.module.FS.writeFile(MAIN_FILE, source);
      // `import Main` triggers compilation, so compile diagnostics appear here;
      // :main then only reports "undefined value: main". Both steps are checked
      // because which one reports depends on whether Main was already loaded.
      importOut = await step('import Main', sent, 30000);
      // The REPL caches compiled modules, so a changed Main.hs is not picked up
      // by re-importing alone. :reload recompiles loaded modules from source.
      reloadOut = await step(':reload', sent, 30000);

      baseline = promptCount();
      mark = state.raw.length;
      sent.push(':main');
      await typeLine(':main');
      await waitUntil(() => promptCount() > baseline, 45000, ':main');
    }

    const res = classify(clean(state.raw.slice(mark), sent));
    const cImport = classify(importOut);
    const cReload = classify(reloadOut);
    const compileRaw = importOut.trim() ? importOut : reloadOut;
    const compileError =
      cImport.error || cReload.error || (compileRaw.trim() ? compileRaw.trim() : null);
    return {
      output: res.output,
      error: compileError || res.error || state.fatal,
      exitCode: state.exitCode == null ? 0 : state.exitCode,
      raw: state.raw,
    };
  } catch (err) {
    return {
      output: null,
      error: String(err && err.message ? err.message : err),
      exitCode: 1,
      raw: state.raw,
    };
  } finally {
    state.running = false;
  }

  /** Type a REPL command, wait for the next prompt, return the cleaned output. */
  async function step(line, sentLines, timeoutMs) {
    const baseline = promptCount();
    const from = state.raw.length;
    sentLines.push(line);
    await typeLine(line);
    await waitUntil(() => promptCount() > baseline, timeoutMs, line);
    return clean(state.raw.slice(from), [line]);
  }
}

/** Is this manifest capable of lazy loading? */
function isLazy() {
  return window.mhsPackages.isLazy(state.manifest);
}

/** Are the given package files all present in this session? */
function hasPackages(names) {
  if (!isLazy() || !names) return true;
  return names.every((n) => state.loaded.indexOf(n) !== -1);
}

/**
 * Record that these packages are needed, so the next boot loads them.
 * The set is monotonic: switching between programs does not reload repeatedly.
 */
function requestPackages(names) {
  const union = Array.from(new Set(state.loaded.concat(names || []))).sort();
  persistPackages(union);
  emit('log', 'packages needed: ' + (names || []).join(', ') + ' — reload to load them');
  return union;
}

window.mhsRepl = {
  boot,
  runHaskell,
  state,
  on,
  PROMPT,
  send: typeLine,
  getRaw: () => state.raw,
  promptCount,
  stdinShim,
  isLazy,
  hasPackages,
  requestPackages,
  persistedPackages,
};
