// Browser entry for the in-page demo: renders DemoRoom events into the
// #demo-root element the host page (site/src/pages/demo/index.astro)
// provides, and wires the visitor's chat box and +1 button.
//
// The engine (lib/demo.dart) is platform-free; this file only builds DOM.
// Uses package:web (not dart:html) so it compiles under dart2wasm.
import 'dart:async';
import 'dart:js_interop';

import 'package:rooms_demo/demo.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  final root = web.document.querySelector('#demo-root');
  if (root == null) return;

  root.innerHTML = '''
    <span class="demo-status"></span>
    <div class="demo-counts"></div>
    <div class="demo-log" aria-live="polite"></div>
    <div class="demo-controls">
      <input class="demo-input" type="text" maxlength="280" aria-label="Chat message"
             placeholder="Message the room">
      <button class="demo-say" type="button">Send</button>
      <button class="demo-plus" type="button">Add a point</button>
    </div>
  '''
      .toJS;

  final status =
      root.querySelector('.demo-status') as web.HTMLSpanElement;
  final countsRow = root.querySelector('.demo-counts') as web.HTMLDivElement;
  final log = root.querySelector('.demo-log') as web.HTMLDivElement;
  final input = root.querySelector('.demo-input') as web.HTMLInputElement;
  final say = root.querySelector('.demo-say') as web.HTMLButtonElement;
  final plusOne = root.querySelector('.demo-plus') as web.HTMLButtonElement;

  void addLine(String line, {String? kind}) {
    final row = web.document.createElement('div');
    if (kind != null) row.className = kind;
    row.textContent = line;
    log.appendChild(row);
    while (log.children.length > 40 && log.firstChild != null) {
      log.removeChild(log.firstChild!);
    }
    log.scrollTop = log.scrollHeight;
  }

  final room = DemoRoom();
  room.events.listen((event) {
    switch (event) {
      case PlayerJoined():
        addLine('${event.name} joined', kind: 'join');
      case ChatLine():
        addLine('${event.from}: ${event.text}');
      case CounterState():
        final chips = [
          for (final entry in event.counts.entries)
            '<span>${entry.key} <b>${entry.value}</b></span>',
        ].join();
        countsRow.innerHTML = chips.toJS;
        status.textContent = 'Room tick ${event.tick}';
      case DemoNote():
        addLine(event.text, kind: 'note');
    }
  });

  Future<void> sendChat() async {
    final text = input.value.trim();
    if (text.isEmpty) return;
    if (await room.visitorSay(text)) input.value = '';
  }

  say.addEventListener(
    'click',
    ((web.Event _) => unawaited(sendChat())).toJS,
  );
  input.addEventListener(
    'keydown',
    ((web.Event e) {
      if ((e as web.KeyboardEvent).key == 'Enter') unawaited(sendChat());
    }).toJS,
  );
  plusOne.addEventListener(
    'click',
    ((web.Event _) => unawaited(room.visitorIncrement())).toJS,
  );
  web.window.addEventListener(
    'beforeunload',
    ((web.Event _) => unawaited(room.dispose())).toJS,
  );

  await room.start();
}
