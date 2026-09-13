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

const state = {
  raw: '',
  ready: false,
  running: false,
  exited: false,
  exitCode: null,
  fatal: null,
  module: null,
};

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

/** Remove prompts, ANSI escapes, echoed input lines and the startup banner. */
function clean(text, sentLines) {
  const noPrompts = text.split(PROMPT).join('');
  // eslint-disable-next-line no-control-regex
  const noAnsi = noPrompts.replace(/\u001b\[[0-9;]*[A-Za-z]/g, '');
  const banner = [
    /^Welcome to interactive MicroHs/,
    /^Integer implemented with imath/,
    /^Loading embedded package /,
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
function boot() {
  return new Promise((resolve, reject) => {
    const rc = ':set prompt=' + PROMPT + '\n';

    const Module = {
      arguments: [],
      locateFile: (p) => 'mhs/' + p,
      preRun: [
        function () {
          Module.FS.mkdirTree(HOME);
          Module.FS.chdir(HOME);
          Module.FS.writeFile('.mhsi_rc', rc);
          Module.FS.writeFile(MAIN_FILE, '');
        },
      ],
      // initRuntime() calls FS.init() with no arguments, which takes these.
      // Input never uses fd 0: it is delivered with _set_input_char.
      stdin: () => null,
      stdout: (code) => code !== null && (state.raw += String.fromCharCode(code)),
      stderr: (code) => code !== null && (state.raw += String.fromCharCode(code)),
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
  if (!state.ready) throw new Error('REPL is not ready');
  if (state.running) throw new Error('a run is already in progress');
  if (state.exited) throw new Error('REPL already exited; reload the page');

  state.running = true;
  const opts = options || {};
  const source = String(opts.source || '');
  const expr = String(opts.expr || '');

  try {
    const sent = [];
    let baseline = promptCount();
    let mark;

    if (opts.mode === 'eval') {
      sent.push(expr);
      mark = state.raw.length;
      await typeLine(expr);
      await waitUntil(() => promptCount() > baseline, 30000, 'expression');
    } else {
      state.module.FS.writeFile(MAIN_FILE, source);
      sent.push('import Main');
      await typeLine('import Main');
      await waitUntil(() => promptCount() > baseline, 30000, 'import Main');

      // The REPL caches compiled modules, so a changed Main.hs is not picked up
      // by re-importing alone. :reload recompiles loaded modules from source.
      baseline = promptCount();
      sent.push(':reload');
      await typeLine(':reload');
      await waitUntil(() => promptCount() > baseline, 30000, ':reload');

      baseline = promptCount();
      mark = state.raw.length;
      sent.push(':main');
      await typeLine(':main');
      await waitUntil(() => promptCount() > baseline, 45000, ':main');
    }

    const res = classify(clean(state.raw.slice(mark), sent));
    return {
      output: res.output,
      error: res.error || state.fatal,
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
};
