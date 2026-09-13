'use strict';

/**
 * Drive the MicroHs interactive REPL to run one Haskell program.
 *
 * Protocol (mirrors web-mhs, verified empirically):
 *   - the REPL is the only execution path in this build (`-r`/`-e` are inert),
 *   - input is delivered with Module._set_input_char, one char at a time,
 *     interleaved with the event loop,
 *   - `.mhsi_rc` sets a sentinel prompt so completion is detectable,
 *   - a program is run with `import Main` then `:main`,
 *   - the REPL echoes typed input, so echoed lines are stripped from output.
 *
 * One program per process: the REPL is a persistent, stateful process.
 *
 * CLI: node node-repl-run.js --file Main.hs [--stdin TEXT] [--timeout MS] [--dump]
 */

const path = require('path');

const MHS_DIR = path.join(__dirname, '..', 'public', 'mhs');
const MHS_JS = path.join(MHS_DIR, 'mhs-embed.js');
const HOME = '/home/web_user';
const PROMPT = '<<<LC_PROMPT>>>';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const dec = new TextDecoder('utf-8', { fatal: false });

function countOccurrences(hay, needle) {
  let n = 0;
  let i = 0;
  while ((i = hay.indexOf(needle, i)) !== -1) {
    n++;
    i += needle.length;
  }
  return n;
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

async function runRepl(options) {
  const opts = options || {};
  const source = String(opts.source || '');
  const stdinText = String(opts.stdin || '');
  const charDelay = opts.charDelay == null ? 2 : opts.charDelay;
  const stepTimeout = opts.timeout || 30000;

  // Interactive: no module args -> the REPL starts.
  process.argv = [process.argv[0], process.argv[1]];

  const raw = { text: '' };
  let exited = false;
  let exitCode = null;

  delete require.cache[require.resolve(MHS_JS)];
  const m = require(MHS_JS);

  m.locateFile = (p) => path.join(MHS_DIR, p);
  m.stdout = (code) => code !== null && (raw.text += String.fromCharCode(code));
  m.stderr = (code) => code !== null && (raw.text += String.fromCharCode(code));
  m.print = () => {};
  m.printErr = (text) => {
    raw.text += String(text) + '\n';
  };
  m.onExit = (code) => {
    exited = true;
    exitCode = code;
  };
  m.preRun = [
    () => {
      const FS = m.FS;
      FS.mkdirTree(HOME);
      FS.chdir(HOME);
      FS.writeFile('.mhsi_rc', ':set prompt=' + PROMPT + '\n');
      FS.writeFile('Main.hs', '');
    },
  ];

  const promptCount = () => countOccurrences(raw.text, PROMPT);

  async function waitFor(label, targetCount, extra) {
    const t0 = Date.now();
    while (Date.now() - t0 < stepTimeout) {
      if (exited) return 'exit';
      if (promptCount() >= targetCount) return 'prompt';
      if (extra && extra()) return 'extra';
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

  function clean(text, sentLines) {
    const banner = [
      /^Welcome to interactive MicroHs/,
      /^Integer implemented with imath/,
      /^Loading embedded package /,
      /^Type ':quit' to quit/,
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

  // Boot: wait for the first prompt.
  await waitFor('first prompt', 1);

  const sent = [];
  let mark;

  if (opts.mode === 'eval') {
    const expr = String(opts.expr || '');
    sent.push(expr);
    mark = raw.text.length;
    await typeLine(expr);
    await waitFor('expression', 2);
  } else {
    m.FS.writeFile('Main.hs', source);

    sent.push('import Main');
    await typeLine('import Main');
    await waitFor('import Main', 2);

    // The REPL caches compiled modules; :reload recompiles from source.
    sent.push(':reload');
    await typeLine(':reload');
    await waitFor(':reload', 3);

    sent.push(':main');
    mark = raw.text.length;
    await typeLine(':main');
    await waitFor(':main', 4);
  }

  const cleaned = clean(raw.text.slice(mark), sent);
  const { output, error } = classify(cleaned);
  void stdinText;

  return {
    output,
    error,
    exitCode: exitCode == null ? 0 : exitCode,
    raw: opts.dump ? raw.text : undefined,
    exited,
  };
}

module.exports = { runRepl, PROMPT };

if (require.main === module) {
  const a = process.argv.slice(2);
  const args = { file: null, stdin: '', timeout: 30000, dump: false, mode: 'run', expr: '' };
  for (let i = 0; i < a.length; i++) {
    if (a[i] === '--file') args.file = a[++i];
    else if (a[i] === '--stdin') args.stdin = a[++i];
    else if (a[i] === '--timeout') args.timeout = Number(a[++i]);
    else if (a[i] === '--dump') args.dump = true;
    else if (a[i] === '--mode') args.mode = a[++i];
    else if (a[i] === '--expr') args.expr = a[++i];
  }
  const fs = require('fs');
  const source = args.file ? fs.readFileSync(args.file, 'utf8') : '';
  runRepl({
    source,
    stdin: args.stdin,
    timeout: args.timeout,
    dump: args.dump,
    mode: args.mode,
    expr: args.expr,
  })
    .then((r) => {
      process.stdout.write(JSON.stringify(r) + '\n');
      process.exit(0);
    })
    .catch((err) => {
      process.stdout.write(JSON.stringify({ error: String(err && err.message) }) + '\n');
      process.exit(1);
    });
}
