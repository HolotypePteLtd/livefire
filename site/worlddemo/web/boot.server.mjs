// Bootstraps the world demo's wasm server: checks WasmGC support first
// (older Safari lacks it) and shows a clear message instead of a broken
// frame, then compiles server.wasm and invokes main(). Copied to
// public/worlddemo/boot.mjs by scripts/build-world-demo.mjs.

// A minimal module with a GC struct type — validates only where WasmGC
// shipped (Chrome 119+, Firefox 120+, Safari 18.2+).
const wasmGcProbe = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 95, 1, 120, 0]);

const root = document.getElementById('world-status');
const fail = (message) => {
  if (root) {
    root.className = 'world-unsupported';
    root.textContent = message;
  }
};

if (typeof WebAssembly !== 'object') {
  fail('This browser cannot run the demo server (WebAssembly is unavailable).');
} else if (!WebAssembly.validate(wasmGcProbe)) {
  fail(
    'This browser lacks WebAssembly GC, which the in-tab server needs. ' +
    'Modern Chrome, Edge, Firefox and Safari 18.2+ run it; older Safari does not.',
  );
} else {
  try {
    const { compileStreaming } = await import('./server.mjs');
    // Absolute path: this boot module lives in /worlddemo/, but it runs in
    // the /world/server/ frame — a bare relative URL would resolve against
    // the page URL and 404.
    const app = await compileStreaming(fetch('/worlddemo/server.wasm'));
    const instance = await app.instantiate({});
    instance.invokeMain();
  } catch (e) {
    fail('The demo server failed to start: ' + e);
  }
}
