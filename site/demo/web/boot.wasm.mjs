// Bootstraps the dart2wasm build of the demo: fetches and compiles
// main.wasm, instantiates it and invokes main(). Copied to
// public/demo/boot.mjs by scripts/build-demo.mjs.
import { compileStreaming } from './main.mjs';

const root = document.getElementById('demo-root');
const fail = (message) => {
  if (root) {
    root.innerHTML = '<p class="demo-error"></p>';
    root.firstChild.textContent = message;
  }
};

if (typeof WebAssembly !== 'object') {
  fail('This browser cannot run the demo (WebAssembly is unavailable).');
} else {
  try {
    const app = await compileStreaming(fetch('main.wasm'));
    const instance = await app.instantiate({});
    instance.invokeMain();
  } catch (e) {
    fail('The demo failed to start: ' + e);
  }
}
