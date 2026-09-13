'use strict';

/**
 * Main-thread client for the MicroHs REPL worker.
 *
 * Owns the timeout for the whole operation (boot + compile + run): on a hang the
 * worker is terminated and a fresh one is spawned for the next run, so a runaway
 * program cannot leave the page unusable.
 * The worker is created from a same-origin URL so `importScripts` is permitted.
 */

(function () {
  const DEFAULT_TIMEOUT = 20000;

  let worker = null;
  let readyPromise = null;
  let bootError = null;
  let nextId = 1;
  const pending = new Map();
  const logHandlers = [];

  function log(message) {
    for (const fn of logHandlers) fn(message);
  }

  function rejectAll(err) {
    for (const [, p] of pending) p.reject(err);
    pending.clear();
  }

  function teardown(err) {
    if (worker) {
      worker.terminate();
      worker = null;
    }
    readyPromise = null;
    bootError = err || null;
    rejectAll(err || new Error('worker terminated'));
  }

  function onMessage(e) {
    const msg = e.data || {};
    if (msg.type === 'log') {
      log('[worker] ' + msg.message);
      return;
    }
    if (msg.type === 'result' || msg.type === 'error') {
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      if (msg.type === 'result') {
        try {
          p.resolve(JSON.parse(msg.json));
        } catch (err) {
          p.reject(new Error('bad result from worker'));
        }
      } else {
        p.reject(new Error(msg.message));
      }
    }
  }

  function ensure() {
    if (worker && readyPromise) return readyPromise;
    if (bootError) return Promise.reject(bootError);

    log('spawning worker');
    worker = new Worker('haskell-worker.js');
    worker.addEventListener('message', onMessage);
    worker.addEventListener('error', (e) => {
      const err = new Error('worker failed to load: ' + (e.message || 'unknown'));
      bootError = err;
      teardown(err);
    });

    readyPromise = new Promise((resolve, reject) => {
      const onReady = (e) => {
        const msg = e.data || {};
        if (msg.type === 'ready') {
          worker.removeEventListener('message', onReady);
          log('worker ready');
          resolve();
        } else if (msg.type === 'fatal') {
          worker.removeEventListener('message', onReady);
          const err = new Error('worker boot failed: ' + msg.message);
          bootError = err;
          teardown(err);
          reject(err);
        }
      };
      worker.addEventListener('message', onReady);
    });

    return readyPromise;
  }

  /**
   * @param {string} source
   * @param {{mode?: 'run'|'eval', expr?: string, timeout?: number}} [options]
   * @returns {Promise<{output: string|null, error: string|null, exitCode: number}>}
   */
  function run(source, options) {
    const opts = options || {};
    const timeout = opts.timeout || DEFAULT_TIMEOUT;

    return new Promise((resolve, reject) => {
      let settled = false;
      const settle = (fn, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(bootTimer);
        fn(value);
      };

      // Covers boot as well as the run: a worker that never becomes ready still
      // fails the call instead of hanging the page forever.
      const bootTimer = setTimeout(() => {
        const err = new Error('Timed out after ' + timeout + ' ms; compiler restarted.');
        teardown(err);
        settle(reject, err);
      }, timeout);

      ensure()
        .then(() => {
          if (settled) return;
          const id = nextId++;
          pending.set(id, {
            resolve: (r) => settle(resolve, r),
            reject: (e) => settle(reject, e),
          });
          worker.postMessage({
            type: 'run',
            id,
            source,
            mode: opts.mode || 'run',
            expr: opts.expr,
            input: opts.input,
          });
        })
        .catch((err) => settle(reject, err));
    });
  }

  window.mhsWorker = {
    ensure,
    run,
    onLog: (fn) => logHandlers.push(fn),
    isRunning: () => pending.size > 0,
    /** Force a fresh worker (used after a timeout or a crashed REPL). */
    restart: () => {
      teardown(null);
      bootError = null;
      return ensure();
    },
    isDead: () => !!bootError,
  };
})();
