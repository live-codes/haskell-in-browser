'use strict';

/**
 * MicroHs REPL worker.
 *
 * Drives the interactive REPL (the only execution path in this build) and reports
 * {output, error, exitCode}. The main thread owns the timeout and terminates this
 * worker on a hang, so an infinite program loop cannot freeze the page.
 *
 * canvhs (Graphics.CanvHs) is NOT available here: it needs a DOM canvas,
 * requestAnimationFrame and Web Audio. Use the main-thread runner for that.
 *
 * Protocol
 *   in : {type:'run', id, source, mode:'run'|'eval', expr}
 *   out: {type:'ready'} | {type:'result', id, json} | {type:'error', id, message} | {type:'fatal', message}
 */

const HOME = '/home/web_user';
const MAIN_FILE = 'Main.hs';
const PROMPT = '<<<LC_PROMPT>>>';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let raw = '';
let booted = false;
let booting = null;
let exitCode = null;
let exited = false;
let abortMessage = null;

function wlog(message) {
  self.postMessage({ type: 'log', message: String(message) });
}

// Same lazy package resolution as the main-thread runner.
importScripts('packages.js');

let pkgFiles = {}; // relative path -> bytes, written into the virtual FS
let pkgMode = false; // lazy manifest present?
let pkgManifest = null;

async function preparePackages(names) {
  pkgManifest = await self.mhsPackages.loadManifest();
  if (!self.mhsPackages.isLazy(pkgManifest)) return;
  pkgMode = true;
  const bytes = await self.mhsPackages.fetchPackages(names || []);
  pkgFiles = {};
  for (const n of Object.keys(bytes)) pkgFiles['packages/' + n] = bytes[n];
  wlog('worker packages: ' + (Object.keys(bytes).join(', ') || 'none'));
}

self.addEventListener('error', (e) => {
  self.postMessage({ type: 'log', message: 'worker error event: ' + (e.message || e) });
});
self.addEventListener('unhandledrejection', (e) => {
  self.postMessage({
    type: 'log',
    message: 'worker unhandledrejection: ' + (e.reason && e.reason.stack ? e.reason.stack : e.reason),
  });
});

let nStdout = 0;
let nPrint = 0;

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
 * so expose the input as pure bindings. Appended to the user's module, which is
 * order-independent in Haskell and needs no imports.
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

function promptCount() {
  let n = 0;
  let i = 0;
  while ((i = raw.indexOf(PROMPT, i)) !== -1) {
    n++;
    i += PROMPT.length;
  }
  return n;
}

async function waitFor(predicate, timeoutMs, label) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (predicate()) return;
    await sleep(10);
  }
  throw new Error('timeout waiting for ' + label);
}

async function typeLine(text) {
  const bytes = new TextEncoder().encode(text + '\n');
  for (const b of bytes) {
    self.Module._set_input_char(b);
    await sleep(0);
  }
}

function stripNoise(text, sentLines) {
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
      /^<interactive>/.test(t) ||
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

function boot() {
  wlog('worker boot: configuring Module');
  self.Module = {
    arguments: Object.keys(pkgFiles).length ? ['-a/pkgs'] : [],
    locateFile: (p) => 'mhs/' + p,
    preRun: [
      function () {
        const FS = self.Module.FS;
        FS.mkdirTree(HOME);
        FS.chdir(HOME);
        FS.writeFile('.mhsi_rc', ':set prompt=' + PROMPT + '\n');
        FS.writeFile(MAIN_FILE, '');
        for (const rel of Object.keys(pkgFiles)) {
          const parts = rel.split('/');
          const file = parts.pop();
          const dir = '/pkgs' + (parts.length ? '/' + parts.join('/') : '');
          FS.mkdirTree(dir);
          FS.writeFile(dir + '/' + file, pkgFiles[rel]);
        }
        if (pkgMode) {
          for (const mod of self.mhsPackages.modulesOf(
            Object.keys(pkgFiles).map((p) => p.replace(/^packages\//, '')),
            pkgManifest,
          )) {
            const path = '/pkgs/' + mod.replace(/\./g, '/') + '.txt';
            FS.mkdirTree(path.slice(0, path.lastIndexOf('/')));
            FS.writeFile(path, pkgManifest.modules[mod]);
          }
        }
        wlog('preRun: FS ready');
      },
    ],
    // initRuntime() calls FS.init() with no arguments, which takes these.
    stdin: () => null,
    stdout: (code) => {
      if (code === null) return;
      nStdout++;
      raw += String.fromCharCode(code);
    },
    stderr: (code) => {
      if (code === null) return;
      nStdout++;
      raw += String.fromCharCode(code);
    },
    print: (text) => {
      nPrint++;
      raw += String(text) + '\n';
    },
    printErr: (text) => {
      raw += String(text) + '\n';
    },
    onExit: (code) => {
      exited = true;
      exitCode = code;
      wlog('onExit ' + code);
    },
    onRuntimeInitialized: () => wlog('onRuntimeInitialized'),
    onAbort: (what) => {
      abortMessage = String(what);
      wlog('onAbort ' + what);
    },
  };

  wlog('importScripts mhs/mhs-embed.js');
  importScripts('mhs/mhs-embed.js');
  wlog('mhs-embed.js evaluated; waiting for prompt');
  wlog('rAF available in worker: ' + (typeof self.requestAnimationFrame));
  setTimeout(() => {
    wlog(
      'tick after import: raw.length=' +
        raw.length +
        ' stdoutCalls=' +
        nStdout +
        ' printCalls=' +
        nPrint +
        ' head=' +
        JSON.stringify(raw.slice(0, 120)),
    );
  }, 500);
  return waitFor(() => promptCount() >= 1, 40000, 'first prompt').then(() => {
    booted = true;
    wlog('REPL ready (prompt seen)');
    self.postMessage({ type: 'ready' });
  });
}

async function runOnce(source, mode, expr, input) {
  const src = String(source || '') + (input ? stdinShim(input) : '');
  self.Module.FS.writeFile(MAIN_FILE, src);
  const sent = [];

  if (mode === 'eval') {
    sent.push(expr);
    let baseline = promptCount();
    const mark = raw.length;
    await typeLine(expr);
    await waitFor(() => promptCount() > baseline, 30000, 'expression');
    const res = classify(stripNoise(raw.slice(mark), sent));
    return { ...res, exitCode: exitCode == null ? 0 : exitCode };
  }

  let baseline = promptCount();
  sent.push('import Main');
  await typeLine('import Main');
  await waitFor(() => promptCount() > baseline, 40000, 'import Main');

  baseline = promptCount();
  const mark = raw.length;
  sent.push(':main');
  await typeLine(':main');
  await waitFor(() => promptCount() > baseline, 60000, ':main');

  const res = classify(stripNoise(raw.slice(mark), sent));
  return { ...res, exitCode: exitCode == null ? 0 : exitCode };
}

self.onmessage = async function (e) {
  const msg = e.data || {};
  if (msg.type !== 'run') return;
  try {
    if (!booted) {
      // Boot lazily so the package set from the caller can be loaded first; the
      // package search path cannot change after boot, so a new set needs a new worker.
      if (!booting) {
        await preparePackages(msg.packages);
        booting = boot();
        booting.catch((err) =>
          self.postMessage({
            type: 'fatal',
            message: String(err && err.message ? err.message : err),
          }),
        );
      }
      await booting;
    }
    if (abortMessage) throw new Error(abortMessage);
    if (exited) throw new Error('REPL exited (exitCode ' + exitCode + '); restart the worker');
    const result = await runOnce(msg.source, msg.mode, msg.expr, msg.input);
    self.postMessage({ type: 'result', id: msg.id, json: JSON.stringify(result) });
  } catch (err) {
    self.postMessage({
      type: 'error',
      id: msg.id,
      message: String(err && err.message ? err.message : err),
    });
  }
};
