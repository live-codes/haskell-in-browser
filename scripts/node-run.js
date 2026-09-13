'use strict';

/**
 * Node-side harness for the MicroHs Emscripten build.
 *
 * Validates the {output, error, exitCode} contract (compile+run, stdin, exit
 * codes, errors, expression eval) without a browser. The same Module
 * configuration is used by the browser runner, public/repl-runner.js.
 *
 * Node-specific caveats (do not apply in the browser):
 *  - The glue's `var Module = typeof Module != "undefined" ? Module : {}` is
 *    shadowed by var-hoisting inside the CommonJS wrapper, so a pre-set
 *    global.Module is ignored. Instead argv is passed via `process.argv`
 *    (the glue's NODE branch reads process.argv.slice(2)) and the remaining
 *    hooks are assigned onto the object returned by require, which happens
 *    before the async wasm instantiation invokes run().
 *  - In the browser, `window.Module` set before the script is picked up
 *    normally, so the browser worker can pass everything upfront.
 *
 * CLI:
 *   node node-run.js --file Main.hs [--stdin TEXT] [--mode run|eval] [--expr E]
 */

const path = require('path');

const MHS_DIR = path.join(__dirname, '..', 'public', 'mhs');
const MHS_JS = path.join(MHS_DIR, 'mhs-embed.js');
const WORK_DIR = '/work';
const MAIN_PATH = WORK_DIR + '/Main.hs';

const decoder = new TextDecoder('utf-8', { fatal: false });

function encode(str) {
  return new TextEncoder().encode(String(str == null ? '' : str));
}

/**
 * @returns {Promise<{output: string|null, error: string|null, exitCode: number}>}
 */
function runHaskell(options) {
  const opts = options || {};
  const source = opts.source || '';
  const expr = opts.expr || '';
  const mode = opts.mode === 'eval' ? 'eval' : 'run';

  const stdinBytes = encode(opts.stdin);
  let stdinPos = 0;

  const outBytes = [];
  const errBytes = [];

  let settled = false;
  let exitCode = null;
  let resolveRun;
  const done = new Promise((resolve) => {
    resolveRun = resolve;
  });

  const finish = (code) => {
    if (settled) return;
    settled = true;
    if (code != null) exitCode = code;

    const output = decoder.decode(new Uint8Array(outBytes));
    const stderr = decoder.decode(new Uint8Array(errBytes));
    resolveRun({
      output: output.length ? output : null,
      error: stderr.length ? stderr : null,
      exitCode: exitCode == null ? 0 : exitCode,
    });
  };

  const argv = opts.argv || (mode === 'eval' ? ['-e' + expr] : ['-r', '-i' + WORK_DIR, 'Main']);

  // The glue reads process.argv.slice(2) in its NODE branch.
  process.argv = [process.argv[0], process.argv[1], ...argv];

  delete require.cache[require.resolve(MHS_JS)];
  const m = require(MHS_JS);

  // Assign before the async run() proceeds.
  m.locateFile = (p) => path.join(MHS_DIR, p);
  m.stdin = () => (stdinPos < stdinBytes.length ? stdinBytes[stdinPos++] : null);
  m.stdout = (b) => outBytes.push(b);
  m.stderr = (b) => errBytes.push(b);
  m.preRun = [
    () => {
      if (mode !== 'run') return;
      const FS = m.FS;
      try {
        FS.mkdir(WORK_DIR);
      } catch (e) {
        /* exists */
      }
      FS.writeFile(MAIN_PATH, String(source));
      // Also expose it in the cwd so file-path arguments resolve.
      FS.writeFile('/Main.hs', String(source));
    },
  ];
  m.onExit = (code) => finish(code);
  m.postRun = [() => finish(exitCode == null ? 0 : exitCode)];
  m.onAbort = () => finish(1);

  return done;
}

module.exports = { runHaskell };

if (require.main === module) {
  const a = process.argv.slice(2);
  const args = { mode: 'run', stdin: '', expr: '', file: null, argv: null };
  for (let i = 0; i < a.length; i++) {
    if (a[i] === '--file') args.file = a[++i];
    else if (a[i] === '--stdin') args.stdin = a[++i];
    else if (a[i] === '--mode') args.mode = a[++i];
    else if (a[i] === '--expr') args.expr = a[++i];
    else if (a[i] === '--argv') args.argv = a[++i].split(',').filter((s) => s !== '');
  }
  const fs = require('fs');
  const source = args.file ? fs.readFileSync(args.file, 'utf8') : '';
  runHaskell({
    source,
    stdin: args.stdin,
    mode: args.mode,
    expr: args.expr,
    argv: args.argv,
  }).then((r) => {
    process.stdout.write(JSON.stringify(r) + '\n');
    process.exit(0);
  });
}
