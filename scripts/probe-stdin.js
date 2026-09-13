'use strict';

/**
 * Can a program read stdin?
 *
 * The web build is compiled with -DUSE_WEB_INPUT, so program stdin plausibly
 * shares the Module._set_input_char queue. The read is synchronous and returns
 * EOF if the queue is empty, so the input must already be queued when the
 * program runs: send ":main" and the stdin text together, without waiting for
 * the prompt in between.
 *
 *   node scripts/probe-stdin.js [stdinText]
 */

const { startRepl } = require('./node-repl-run');

const SOURCE = [
  'module Main where',
  'main :: IO ()',
  'main = do',
  '  s <- getLine',
  '  putStrLn ("got: " ++ s)',
  '',
].join('\n');

const stdinText = process.argv[2] == null ? 'world' : process.argv[2];

async function main() {
  const s = await startRepl({});
  s.m.FS.writeFile('Main.hs', SOURCE);

  await s.step('import Main');
  await s.step(':reload');

  const baseline = s.promptCount();
  const mark = s.state.raw.length;

  // Queue the command AND the program's stdin in one go.
  await s.typeLine(':main');
  await s.typeLine(stdinText);

  const t0 = Date.now();
  while (Date.now() - t0 < 15000 && s.promptCount() <= baseline) {
    await new Promise((r) => setTimeout(r, 20));
  }

  const slice = s.state.raw.slice(mark);
  console.log('stdin sent      :', JSON.stringify(stdinText));
  console.log('raw slice       :', JSON.stringify(slice));
  console.log('cleaned         :', JSON.stringify(s.clean(slice, [':main', stdinText])));
  console.log('read stdin?     :', new RegExp('got: ' + stdinText).test(slice));
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error('probe failed:', err && err.message);
    process.exit(1);
  },
);
