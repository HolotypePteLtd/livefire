// Both the homepage and the multiplayer guide use this embed. Give each
// page its own room and load the server and clients when the demo is in view.
(function () {
  var host = document.getElementById('world-demo-frames');
  if (!host || host.childElementCount > 0) return;

  function start() {
    if (host.childElementCount > 0) return; // already started
    var session =
      (window.crypto && crypto.randomUUID)
        ? crypto.randomUUID().slice(0, 8)
        : Math.random().toString(36).slice(2, 10);

    var frames = [
      { src: '/world/server/?c=' + session, cls: 'world-server', title: 'Server: wasm room engine' },
      { src: '/world/client/?c=' + session, cls: '', title: 'Client A: your blue avatar (WASD / arrows)' },
      { src: '/world/client/?c=' + session + '&bot=1', cls: '', title: 'Client B: scripted red avatar' },
    ];
    frames.forEach(function (f) {
      var iframe = document.createElement('iframe');
      iframe.src = f.src;
      iframe.title = f.title;
      if (f.cls) iframe.className = f.cls;
      iframe.loading = 'lazy';
      host.appendChild(iframe);
    });
  }

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(
      function (entries) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].isIntersecting) {
            observer.disconnect();
            start();
            break;
          }
        }
      },
      // Start just before the section is fully on screen, so the frames
      // are alive by the time the reader's eye arrives.
      { rootMargin: '200px 0px' },
    );
    observer.observe(host);
  } else {
    // No IntersectionObserver (very old browser): start immediately —
    // the script tag is deferred, so the DOM is ready.
    start();
  }
})();
