'use strict';

/**
 * JavaScript glue that the canvhs package imports from wasm (see the page's
 * ASM_CONSTS in mhs-embed.js). Mirrors the helpers defined by web-mhs's
 * index.html so `import Graphics.CanvHs` works in the spike page.
 *
 * Draw text: the wasm calls drawHaskellText(ptr); UTF8ToString is a global
 * provided by mhs-embed.js once it has loaded.
 */

const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d', { alpha: false });

window.cvs = canvas;
window.ctx = ctx;
window.mouseState = { x: 0.0, y: 0.0, down: false };

function resizeCanvas() {
  const rect = canvas.getBoundingClientRect();
  if (canvas.width !== rect.width || canvas.height !== rect.height) {
    canvas.width = rect.width;
    canvas.height = rect.height;
  }
}
resizeCanvas();
window.addEventListener('resize', resizeCanvas);

window.showCanvas = function () {
  resizeCanvas();
};
window.hideCanvas = function () {
  /* the canvas is always visible in this harness */
};

/** Draw a string at the current transform position, un-flipped. */
window.drawHaskellText = function (textPtr) {
  const str = window.UTF8ToString ? window.UTF8ToString(textPtr) : String(textPtr);
  const matrix = ctx.getTransform();
  ctx.save();
  ctx.resetTransform();
  if (ctx.font !== '24px monospace') ctx.font = '24px monospace';
  ctx.textBaseline = 'middle';
  ctx.fillText(str, Math.round(matrix.e), Math.round(matrix.f));
  ctx.restore();
};

// ---- mouse ----
function updateMousePos(e) {
  const rect = canvas.getBoundingClientRect();
  window.mouseState.x = e.clientX - rect.left - rect.width / 2;
  window.mouseState.y = rect.height / 2 - (e.clientY - rect.top);
}
canvas.addEventListener('mousemove', updateMousePos);
canvas.addEventListener('mousedown', (e) => {
  updateMousePos(e);
  window.mouseState.down = true;
});
canvas.addEventListener('mouseup', (e) => {
  updateMousePos(e);
  window.mouseState.down = false;
});

// ---- audio (canvhs sound) ----
window.audioCtx = null;
window.audioNodes = [];

window.js_initAudio = function () {
  if (!window.audioCtx) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;
    window.audioCtx = new Ctx();
    window.audioNodes = [window.audioCtx.destination];
  }
  if (window.audioCtx.state === 'suspended') window.audioCtx.resume();
};

window.js_currentTime = function () {
  return window.audioCtx ? window.audioCtx.currentTime : 0;
};

window.js_createOscillator = function (waveType) {
  const osc = window.audioCtx.createOscillator();
  osc.type = ['sine', 'square', 'sawtooth', 'triangle'][waveType];
  const id = window.audioNodes.length;
  window.audioNodes.push(osc);
  return id;
};

window.js_createGain = function () {
  const gain = window.audioCtx.createGain();
  const id = window.audioNodes.length;
  window.audioNodes.push(gain);
  return id;
};

window.js_connect = function (sourceId, targetId) {
  window.audioNodes[sourceId].connect(window.audioNodes[targetId]);
};

window.js_setFrequency = function (id, freq, time) {
  window.audioNodes[id].frequency.setValueAtTime(freq, time);
};

window.js_setGain = function (id, vol, time) {
  window.audioNodes[id].gain.setValueAtTime(vol, time);
};

window.js_rampGain = function (id, vol, time) {
  window.audioNodes[id].gain.exponentialRampToValueAtTime(vol, time);
};

window.js_startNode = function (id, time) {
  window.audioNodes[id].start(time);
};

window.js_stopNode = function (id, time) {
  window.audioNodes[id].stop(time);
};
