'use strict';

/**
 * Headless verification of the MicroHs REPL protocol.
 *
 * Spawns one process per case (the REPL is stateful/persistent), driving it with
 * scripts/node-repl-run.js. Mirrors the browser harness (public/repl-runner.js).
 *
 *   node scripts/node-test.js
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const RUNNER = path.join(__dirname, 'node-repl-run.js');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'mhs-repl-'));

const cases = [
  {
    name: 'putStrLn program',
    source: 'module Main where\nmain :: IO ()\nmain = putStrLn "hello from MicroHs"\n',
    check: (r) => r.exitCode === 0 && /hello from MicroHs/.test(r.output || ''),
  },
  {
    name: 'numeric stdout',
    source: 'module Main where\nmain :: IO ()\nmain = print (sum [1 .. 10] :: Int)\n',
    check: (r) => r.exitCode === 0 && /^55$/m.test(r.output || ''),
  },
  {
    name: 'expression eval',
    mode: 'eval',
    expr: 'map (+1) [1..5]',
    check: (r) => r.exitCode === 0 && /\[2,3,4,5,6\]/.test(r.output || ''),
  },
  {
    name: 'partial function reported as error',
    source: 'module Main where\nmain :: IO ()\nmain = print (head ([] :: [Int]))\n',
    check: (r) => r.error != null && /head: empty list/.test(r.error),
  },
  {
    name: 'undefined binding reported as error',
    source: 'module Main where\nmain :: IO ()\nmain = print nope\n',
    check: (r) => r.error != null || r.exitCode !== 0,
  },
];

let pass = 0;
let fail = 0;

for (const c of cases) {
  const file = path.join(TMP, 'Main.hs');
  fs.writeFileSync(file, c.source || '');

  const args = [RUNNER];
  if (c.mode === 'eval') args.push('--mode', 'eval', '--expr', c.expr);
  else args.push('--file', file);

  const t0 = Date.now();
  const proc = spawnSync(process.execPath, args, { encoding: 'utf8', timeout: 90000 });
  const ms = Date.now() - t0;

  let result;
  try {
    result = JSON.parse(proc.stdout.trim().split('\n').pop());
  } catch (err) {
    result = {
      output: null,
      error: 'unparseable output: ' + proc.stdout + proc.stderr,
      exitCode: -1,
    };
  }

  const ok = c.check(result);
  if (ok) pass++;
  else fail++;

  console.log((ok ? 'PASS' : 'FAIL') + `  ${c.name}  (${ms} ms)`);
  console.log(
    '      ' + JSON.stringify({ output: result.output, error: result.error, exitCode: result.exitCode }),
  );
}

console.log(`\n${pass} passed, ${fail} failed`);
fs.rmSync(TMP, { recursive: true, force: true });
process.exit(fail === 0 ? 0 : 1);
