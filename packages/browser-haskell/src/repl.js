import { createPackageResolver } from './manifest.js';
import { injectStdin } from './shim.js';

/**
 * MicroHs REPL driver.
 *
 * The published `mhs-embed` bundle cannot compile and run in batch mode, so the only
 * execution path is the interactive REPL: write Main.hs, `import Main` (which compiles,
 * so diagnostics surface here), `:reload` (the REPL caches modules, so a changed file is
 * otherwise ignored), then `:main` (which runs it). Output is read between sentinel
 * prompts.
 *
 * Program stdin does not exist at the OS level in this build, so it is injected into the
 * source instead — see shim.js.
 */

const HOME = '/home/web_user';
const MAIN_FILE = 'Main.hs';
const PROMPT = '<<<LC_PROMPT>>>';
const PKG_DIR = '/pkgs';
const BOOT_TIMEOUT = 30000;
const DEFAULT_TIMEOUT = 60000;

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Load the Emscripten glue, wherever this is running. */
async function loadScript(url) {
  if (typeof document !== 'undefined' && document.createElement) {
    await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = url;
      script.onload = () => resolve();
      script.onerror = () => reject(new Error('failed to load ' + url));
      (document.head || document.body || document.documentElement).appendChild(script);
    });
    return;
  }
  if (typeof importScripts === 'function') {
    importScripts(url);
    return;
  }
  // Module worker (or Node, if someone points wasmUrl at a file URL).
  await import(/* webpackIgnore: true */ /* @vite-ignore */ url);
}

/** Backspaces delete the previous character, as a terminal would. */
function applyBackspaces(text) {
  let out = '';
  for (const ch of text) {
    if (ch === '\b') out = out.slice(0, -1);
    else out += ch;
  }
  return out;
}

/** Progress lines ("adds [ ]\radds [x]") keep only their final state. */
function applyCarriageReturns(text) {
  return text
    .split('\n')
    .map((line) => {
      const i = line.lastIndexOf('\r');
      return i >= 0 ? line.slice(i + 1) : line;
    })
    .join('\n');
}

/** Drop prompts, ANSI control sequences, echoed input and REPL banner lines. */
function clean(text, sentLines) {
  const noPrompts = text.split(PROMPT).join('');
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
      if ((sentLines || []).some((s) => t === s)) return false;
      return true;
    })
    .join('\n');
}

/** Is this line an error/diagnostic rather than program output? */
function isErrorLine(line) {
  const t = line.trim();
  return (
    /^(\*\*\* )?(Exception|error:|Error:)/.test(t) ||
    /^Unrecognized command/.test(t) ||
    // The compiler explains failed constraint solving on its own lines, on stdout.
    /^fully qualified:/.test(t) ||
    /: line \d+, col \d+:/.test(t)
  );
}

function classify(text) {
  const out = [];
  const errors = [];
  for (const line of text.split('\n')) (isErrorLine(line) ? errors : out).push(line);
  return { out, errors };
}

const joinLines = (lines) => lines.join('\n').trim();

/**
 * One MicroHs instance. Booting is expensive (~1-2s: 1.9 MB wasm), so create one and
 * reuse it for every run in the page/worker.
 */
export class MicroHs {
  constructor(options) {
    const opts = options || {};
    this.options = {
      wasmUrl: opts.wasmUrl,
      packagesUrl: opts.packagesUrl,
      importmap: opts.importmap || {},
      timeout: opts.timeout || DEFAULT_TIMEOUT,
      charDelay: opts.charDelay == null ? 0 : opts.charDelay,
      onLog: typeof opts.onLog === 'function' ? opts.onLog : null,
      fetch: opts.fetch,
    };

    this.raw = '';
    this.out = '';
    this.err = '';
    this.outDecoder = new TextDecoder('utf-8', { fatal: false });
    this.errDecoder = new TextDecoder('utf-8', { fatal: false });
    this.loaded = new Set();
    this.exitCode = null;
    this.fatal = null;
    this.ready = false;
    this.running = false;
    this.disposed = false;
    /** Set once a run has timed out: the REPL is mid-execution and cannot be reused. */
    this.poisoned = null;
    this.Module = null;
    this.resolver = null;
  }

  log(message) {
    if (this.options.onLog) this.options.onLog(message);
  }

  promptCount() {
    let n = 0;
    let i = 0;
    while ((i = this.raw.indexOf(PROMPT, i)) !== -1) {
      n++;
      i += PROMPT.length;
    }
    return n;
  }

  async waitFor(predicate, label, deadline) {
    for (;;) {
      if (predicate()) return;
      if (this.fatal) throw new Error(this.fatal);
      if (Date.now() > deadline) {
        const err = new Error('timed out waiting for ' + label);
        err.timeout = true;
        throw err;
      }
      await delay(1);
    }
  }

  /** Type a line into the REPL one character at a time, yielding between them. */
  async typeLine(text, deadline) {
    const bytes = new TextEncoder().encode(text + '\n');
    for (const byte of bytes) {
      if (Date.now() > deadline) {
        const err = new Error('timed out while sending input');
        err.timeout = true;
        throw err;
      }
      this.Module._set_input_char(byte);
      await delay(this.options.charDelay);
    }
  }

  /** Type a REPL command and wait for the output it produces. */
  async step(line, deadline) {
    const baseline = this.promptCount();
    await this.typeLine(line, deadline);
    await this.waitFor(() => this.promptCount() > baseline, JSON.stringify(line), deadline);
  }

  /** Boot the compiler. Resolves once the REPL shows its first prompt. */
  async boot() {
    this.resolver = createPackageResolver({
      packagesUrl: this.options.packagesUrl,
      importmap: this.options.importmap,
      log: (m) => this.log(m),
      fetch: this.options.fetch,
    });
    await this.resolver.loadManifest();

    const wasmUrl = String(this.options.wasmUrl);
    const wasmDir = wasmUrl.slice(0, wasmUrl.lastIndexOf('/') + 1);

    const Module = {
      // `-aPATH` appends to the package search path. Declaring it up front (even while
      // /pkgs is empty) is what lets packages be written into the virtual FS later and
      // imported without restarting the REPL.
      arguments: ['-a' + PKG_DIR],
      locateFile: (file) => wasmDir + file,
      preRun: [
        function () {
          const FS = Module.FS;
          FS.mkdirTree(HOME);
          FS.chdir(HOME);
          FS.writeFile('.mhsi_rc', ':set prompt=' + PROMPT + '\n');
          FS.writeFile(MAIN_FILE, '');
        },
      ],
      // Program stdin is unusable here; it is injected as source instead (shim.js).
      stdin: () => null,
      stdout: (code) => code !== null && this.appendOut(code),
      stderr: (code) => code !== null && this.appendErr(code),
      print: (text) => this.appendOut(text + '\n'),
      printErr: (text) => this.appendErr(text + '\n'),
      onExit: (code) => {
        this.exitCode = code;
        this.log('compiler exited with ' + code);
      },
      onAbort: (what) => {
        this.fatal = String(what);
      },
    };

    this.Module = Module;
    // The glue is a classic script that reads a global `Module`.
    globalThis.Module = Module;

    this.log('loading ' + wasmUrl);
    await loadScript(wasmUrl);
    await this.waitFor(() => this.promptCount() > 0, 'the REPL to start', Date.now() + BOOT_TIMEOUT);
    this.ready = true;
    this.log('ready');
    return this;
  }

  appendOut(text) {
    const s = typeof text === 'number' ? this.outDecoder.decode(new Uint8Array([text]), { stream: true }) : String(text);
    this.out += s;
    this.raw += s;
  }

  appendErr(text) {
    const s = typeof text === 'number' ? this.errDecoder.decode(new Uint8Array([text]), { stream: true }) : String(text);
    this.err += s;
    this.raw += s;
  }

  /**
   * Write package files into the live virtual FS, plus the module lookup maps that point
   * at them. No restart, no page reload: the search path was declared at boot.
   * @returns {Promise<string[]>} package files actually written
   */
  async loadPackages(names, urls) {
    const want = (names || []).filter((name) => !this.loaded.has(name));
    if (!want.length) return [];

    const bytes = await this.resolver.fetchPackages(want, urls);
    const got = Object.keys(bytes);
    if (!got.length) return [];

    const FS = this.Module.FS;
    FS.mkdirTree(PKG_DIR + '/packages');
    for (const name of got) FS.writeFile(PKG_DIR + '/packages/' + name, bytes[name]);
    this.writeModuleMaps(got);
    for (const name of got) this.loaded.add(name);
    this.log('loaded ' + got.length + ' package(s): ' + got.join(', '));
    return got;
  }

  /** `<Module/Path>.txt` containing the package file name, for each provided module. */
  writeModuleMaps(pkgFiles) {
    const FS = this.Module.FS;
    for (const mod of this.resolver.modulesOf(pkgFiles)) {
      const pkg = this.resolver.packageOfModule(mod);
      if (!pkg) continue;
      const path = PKG_DIR + '/' + mod.replace(/\./g, '/') + '.txt';
      FS.mkdirTree(path.slice(0, path.lastIndexOf('/')));
      FS.writeFile(path, pkg);
    }
  }

  /**
   * Compile and run a program.
   * @param {{code: string, stdin?: string, timeout?: number}} options
   * @returns {Promise<{stdout:string, stderr:string, error:string|null, output:string,
   *   exitCode:number, packages:string[], durationMs:number}>}
   */
  async run(options) {
    const opts = options || {};
    if (this.disposed) throw new Error('this instance has been disposed');
    if (this.poisoned) throw new Error(this.poisoned);
    if (!this.ready) throw new Error('the REPL is not ready');
    if (this.running) throw new Error('a run is already in progress');

    const timeout = opts.timeout || this.options.timeout;
    const deadline = Date.now() + timeout;
    const source = injectStdin(opts.code, opts.stdin);

    // Imports that can never be satisfied are reported before anything is compiled.
    const analysis = this.resolver.analyzeImports(source);
    if (analysis.missing.length) {
      return this.result({ error: this.resolver.explainMissing(analysis.missing) });
    }

    const loaded = await this.loadPackages(analysis.packages, analysis.urls);
    const absent = analysis.packages.filter((name) => !this.loaded.has(name));
    if (absent.length) {
      return this.result({ error: 'package file(s) missing from this build: ' + absent.join(', '), packages: loaded });
    }

    const mark = { raw: this.raw.length, out: this.out.length, err: this.err.length };
    const sent = [];
    const started = Date.now();
    let timedOut = false;

    this.running = true;
    try {
      this.Module.FS.writeFile(MAIN_FILE, source);
      // `import Main` compiles, so diagnostics appear here; :reload is what actually
      // picks up a changed file; :main runs it.
      for (const line of ['import Main', ':reload', ':main']) {
        sent.push(line);
        await this.step(line, deadline);
      }
    } catch (err) {
      timedOut = !!err.timeout;
      if (!timedOut) this.fatal = String((err && err.message) || err);
    } finally {
      this.running = false;
    }

    const collected = this.collect(mark, sent);
    if (timedOut) {
      this.poisoned = 'the previous run timed out and left the REPL busy; create a new instance';
    }

    return this.result({
      ...collected,
      error:
        collected.error ||
        (timedOut ? 'timed out after ' + timeout + 'ms' : null) ||
        (this.fatal ? this.fatal : null),
      exitCode: timedOut ? 124 : undefined,
      packages: loaded,
      durationMs: Date.now() - started,
    });
  }

  /** Split the output captured since `mark` into stdout, stderr and diagnostics. */
  collect(mark, sent) {
    const outC = classify(clean(this.out.slice(mark.out), sent));
    const errC = classify(clean(this.err.slice(mark.err), sent));
    const errors = [];
    for (const line of outC.errors.concat(errC.errors)) {
      if (!errors.includes(line)) errors.push(line);
    }
    const error = joinLines(errors);
    return {
      stdout: joinLines(outC.out),
      stderr: joinLines(errC.out),
      error: error ? this.resolver.explainNotFound(error) : null,
      output: clean(this.raw.slice(mark.raw), sent).trim(),
    };
  }

  result(extra) {
    const error = extra.error || null;
    const exitCode =
      extra.exitCode != null ? extra.exitCode : error ? 1 : this.exitCode == null ? 0 : this.exitCode;
    return {
      stdout: extra.stdout || '',
      stderr: extra.stderr || '',
      error,
      output: extra.output || '',
      exitCode,
      packages: extra.packages || [],
      durationMs: extra.durationMs == null ? 0 : extra.durationMs,
    };
  }

  /**
   * Release this instance. Browsers cannot unload a wasm module, so this drops our
   * references rather than freeing memory; one instance per page/worker is the model.
   */
  dispose() {
    this.disposed = true;
    this.Module = null;
    this.resolver = null;
    this.loaded.clear();
  }
}
