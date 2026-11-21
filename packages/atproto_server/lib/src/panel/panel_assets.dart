/// The panel's static assets, embedded in the node binary (no build
/// step, no file IO, same-origin). Vanilla HTML/CSS/JS only — no inline
/// script or style, so the CSP served with them (`script-src 'self'` …)
/// leaves a reflected value nowhere to execute.
///
/// Visual conventions follow the docs site (`site/src/styles`): near-black
/// cool surfaces, ember-amber primary, cyan secondary, mono headings.
library;

const String panelPageHtml = r'''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Livefire — developer panel</title>
<link rel="stylesheet" href="/panel/panel.css?v=2">
<link rel="icon" href="data:,">
</head>
<body>
<header class="top">
  <span class="logo">Open<span class="accent">fire</span> <span class="dim">panel</span> <span id="mode-badge" class="badge hidden"></span></span>
  <span id="who" class="who"></span>
</header>
<main id="main">
  <section id="state" class="card">
    <p id="state-msg" class="msg">Loading…</p>
    <form id="signin" class="signin hidden" autocomplete="off">
      <p>Sign in with your Bluesky account to manage API keys.</p>
      <div class="row">
        <input id="handle" type="text" placeholder="you.bsky.social" spellcheck="false" required>
        <button id="signin-btn" type="submit">Sign in with Bluesky</button>
      </div>
      <p id="signin-err" class="err hidden" aria-live="polite"></p>
      <div id="signin-wait" class="row hidden">
        <span class="hint" role="status">waiting for sign-in…</span>
        <button id="signin-cancel" type="button">Cancel</button>
      </div>
    </form>
  </section>

  <section id="dashboard" class="hidden">
    <section class="card" id="admins-card">
      <h2>Admins</h2>
      <p class="hint">Who can sign in here. Cannot revoke yourself or the last admin.</p>
      <form id="promote-admin" class="row" autocomplete="off">
        <input id="admin-input" type="text" placeholder="did:plc:… or handle.bsky.social" spellcheck="false" required>
        <button type="submit">Promote</button>
      </form>
      <p id="admin-err" class="err hidden"></p>
      <div class="scroll">
        <table>
          <thead><tr><th>did</th><th>added by</th><th>created</th><th></th></tr></thead>
          <tbody id="admins"></tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2>API keys</h2>
      <p class="hint">Keys are shown in full exactly once, when created. Only a hash is stored.</p>
      <form id="create-key" class="row" autocomplete="off">
        <input id="label" type="text" placeholder="key label — e.g. my game backend" spellcheck="false" required maxlength="64">
        <button type="submit">Create key</button>
      </form>
      <form id="create-key-scopes" class="row scopes hidden" autocomplete="off">
        <input id="max-rooms" type="text" inputmode="numeric" placeholder="max rooms — blank = unlimited" spellcheck="false">
        <input id="templates" type="text" placeholder="templates, comma-separated — blank = all" spellcheck="false">
      </form>
      <div id="new-key" class="newkey hidden">
        <p class="hint warn">Copy it now — it will not be shown again:</p>
        <div class="row"><code id="new-key-value"></code><button id="copy-key" type="button">Copy</button></div>
      </div>
      <div class="scroll">
        <table>
          <thead><tr><th>key</th><th>label</th><th>scope</th><th>created</th><th>rooms</th><th>tokens</th><th></th></tr></thead>
          <tbody id="keys"></tbody>
        </table>
      </div>
      <p class="hint">Rows marked <span class="badge">bootstrap</span> come from node.json — read-only here; remove them from the config and restart.</p>
    </section>

    <section class="card">
      <h2>Rooms</h2>
      <p class="hint">Live rooms on this node (read-only). <button id="refresh" type="button" class="link">Refresh</button></p>
      <div class="scroll">
        <table>
          <thead><tr><th>room</th><th>template</th><th>status</th><th>peers</th><th>age</th></tr></thead>
          <tbody id="rooms"></tbody>
        </table>
      </div>
    </section>

    <section class="card" id="audit-card">
      <h2>Audit log</h2>
      <p class="hint">Every mutating panel action, newest first. <button id="refresh-audit" type="button" class="link">Refresh</button></p>
      <div class="scroll">
        <table>
          <thead><tr><th>when</th><th>actor</th><th>action</th><th>target</th><th>details</th></tr></thead>
          <tbody id="audit"></tbody>
        </table>
      </div>
    </section>
  </section>
</main>
<script src="/panel/app.js?v=2"></script>
</body>
</html>
''';

const String panelCss = r'''
:root {
  --bg: #0b0d12; --panel: #12151d; --panel-2: #171b25;
  --text: #edf1f7; --muted: #97a1b5; --faint: #74809a;
  --ember: #f5a54a; --cyan: #57c8de; --green: #57d9a3; --red: #e06c75;
  --line: #242b3a;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.5 var(--sans);
}
.top {
  display: flex; align-items: center; justify-content: space-between;
  padding: 0.8rem 1.2rem; border-bottom: 1px solid var(--line);
  background: var(--panel);
}
.logo { font-family: var(--mono); font-weight: 700; letter-spacing: 0.02em; }
.logo .accent { color: var(--ember); }
.dim { color: var(--faint); font-weight: 400; }
.who { color: var(--muted); font-family: var(--mono); font-size: 0.85rem; }
main { max-width: 880px; margin: 1.5rem auto 4rem; padding: 0 1rem; display: grid; gap: 1.2rem; }
.card {
  background: var(--panel); border: 1px solid var(--line);
  border-radius: 10px; padding: 1.1rem 1.2rem;
}
h2 { margin: 0 0 0.4rem; font-size: 1rem; font-family: var(--mono); letter-spacing: 0.04em; text-transform: uppercase; color: var(--ember); }
.hint { color: var(--muted); font-size: 0.85rem; margin: 0.2rem 0 0.8rem; }
.warn { color: var(--ember); }
.msg { margin: 0; color: var(--muted); }
.err { color: var(--red); font-size: 0.9rem; }
.row { display: flex; gap: 0.6rem; align-items: center; flex-wrap: wrap; margin: 0.6rem 0; }
input[type="text"] {
  flex: 1; min-width: 220px; background: var(--bg); color: var(--text);
  border: 1px solid var(--line); border-radius: 6px; padding: 0.5rem 0.7rem;
  font: 0.9rem var(--mono);
}
input[type="text"]:focus { outline: 1px solid var(--cyan); }
form.scopes input { min-width: 180px; }
button {
  background: var(--ember); color: #221204; font-weight: 600;
  border: 0; border-radius: 6px; padding: 0.5rem 0.9rem; cursor: pointer;
}
button:hover { filter: brightness(1.1); }
button.link { background: none; color: var(--cyan); padding: 0; text-decoration: underline; }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.88rem; }
th { text-align: left; color: var(--faint); font-family: var(--mono); font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.06em; padding: 0.4rem 0.6rem; border-bottom: 1px solid var(--line); }
td { padding: 0.45rem 0.6rem; border-bottom: 1px solid var(--line); color: var(--muted); vertical-align: top; }
td code, #new-key-value { font-family: var(--mono); color: var(--text); font-size: 0.85rem; }
td.details code { color: var(--muted); font-size: 0.78rem; }
td.did code { word-break: break-all; }
.badge {
  display: inline-block; border: 1px solid var(--line); border-radius: 999px;
  color: var(--cyan); font-family: var(--mono); font-size: 0.68rem;
  padding: 0.05rem 0.5rem; text-transform: uppercase; letter-spacing: 0.06em;
}
.badge.revoked { color: var(--red); text-decoration: none; }
.badge.pg { color: var(--green); }
.scope { font-family: var(--mono); font-size: 0.78rem; color: var(--muted); }
.revoked-row td { opacity: 0.5; }
.newkey { background: var(--panel-2); border: 1px solid var(--line); border-radius: 8px; padding: 0.7rem 0.9rem; }
#new-key-value { word-break: break-all; }
.hidden { display: none !important; }
button.small { padding: 0.25rem 0.6rem; font-size: 0.8rem; background: none; border: 1px solid var(--line); color: var(--muted); }
button.small:hover { color: var(--red); border-color: var(--red); filter: none; }
''';

const String panelAppJs = r'''
// Livefire developer panel — vanilla JS, no dependencies. The session is
// a ps_ bearer token (12 h) kept in localStorage and sent on every API
// call; sign-in runs the node's atproto OAuth flow in a popup while this
// page polls its result.
//
// The session response carries the persistence mode: in 'postgres' mode
// (SUPABASE_URL + SUPABASE_SECRET_KEY set) the admin list is managed
// here, keys take scopes and the audit log is shown; in 'sqlite' mode
// those sections stay hidden and admins live in node.json.
'use strict';

const $ = (id) => document.getElementById(id);
const SESSION_KEY = 'openfire_panel_session';
let session = localStorage.getItem(SESSION_KEY) || '';
let mode = 'sqlite';
let canManageAdmins = false;

async function api(path, options) {
  const response = await fetch(path, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(session ? { Authorization: 'Bearer ' + session } : {}),
      ...(options && options.headers) || {},
    },
  });
  const body = await response.json().catch(() => ({}));
  return { status: response.status, body };
}

function show(id) {
  for (const el of ['state', 'signin', 'dashboard']) $(el).classList.add('hidden');
  $(id).classList.remove('hidden');
}

function fmtDate(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' });
}

function fmtAge(seconds) {
  if (seconds < 60) return seconds + 's';
  if (seconds < 3600) return Math.round(seconds / 60) + 'm';
  if (seconds < 86400) return Math.round(seconds / 3600) + 'h';
  return Math.round(seconds / 86400) + 'd';
}

async function init() {
  if (!session) return signedOut();
  const me = await api('/panel/api/session');
  if (me.status === 200) return dashboard(me.body);
  if (me.status === 403) return notAuthorized(me.body);
  localStorage.removeItem(SESSION_KEY);
  session = '';
  signedOut();
}

function signedOut() {
  show('state');
  $('signin').classList.remove('hidden');
  $('state-msg').textContent = '';
}

function notAuthorized(body) {
  show('state');
  const message = body && body.error ? body.error.message : 'not authorized';
  $('state-msg').textContent =
    'Signed in, but this account is not a panel admin (' + message + '). ' +
    'Ask a node admin to promote your DID.';
}

function dashboard(me) {
  show('dashboard');
  mode = me.mode || 'sqlite';
  canManageAdmins = !!me.canManageAdmins;
  const badge = $('mode-badge');
  badge.textContent = mode === 'postgres' ? 'postgres' : 'sqlite';
  badge.classList.remove('hidden');
  if (mode !== 'postgres') badge.classList.add('pg');
  $('who').textContent = (me.handle || me.did) + ' · admin';
  $('create-key-scopes').classList.toggle('hidden', mode !== 'postgres');
  $('admins-card').classList.toggle('hidden', !canManageAdmins);
  $('audit-card').classList.toggle('hidden', mode !== 'postgres');
  loadKeys();
  loadRooms();
  if (canManageAdmins) loadAdmins();
  if (mode === 'postgres') loadAudit();
}

async function loadKeys() {
  const { body } = await api('/panel/api/keys');
  const rows = $('keys');
  rows.textContent = '';
  for (const key of body.keys || []) {
    const tr = document.createElement('tr');
    if (key.revokedAt) tr.className = 'revoked-row';
    const keyCell = document.createElement('td');
    const code = document.createElement('code');
    code.textContent = key.keyPrefix + '…';
    keyCell.appendChild(code);
    if (key.bootstrap) {
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = 'bootstrap';
      keyCell.appendChild(document.createTextNode(' '));
      keyCell.appendChild(badge);
    }
    if (key.revokedAt) {
      const badge = document.createElement('span');
      badge.className = 'badge revoked';
      badge.textContent = 'revoked';
      keyCell.appendChild(document.createTextNode(' '));
      keyCell.appendChild(badge);
    }
    tr.appendChild(keyCell);
    const label = document.createElement('td');
    label.textContent = key.label;
    tr.appendChild(label);
    const scope = document.createElement('td');
    scope.className = 'scope';
    scope.textContent = key.maxRooms == null && key.templates == null
      ? 'unlimited'
      : (key.maxRooms == null ? '∞ rooms' : key.maxRooms + ' rooms') +
        ' · ' + (key.templates == null ? 'all' : key.templates.join(', '));
    tr.appendChild(scope);
    for (const text of [
      fmtDate(key.createdAt),
      String(key.roomsCreated),
      String(key.tokensMinted),
    ]) {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    }
    const action = document.createElement('td');
    if (!key.bootstrap && !key.revokedAt) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'small';
      btn.textContent = 'Revoke';
      btn.addEventListener('click', () => revokeKey(key.id, key.label));
      action.appendChild(btn);
    }
    tr.appendChild(action);
    rows.appendChild(tr);
  }
}

async function loadRooms() {
  const { body } = await api('/panel/api/rooms');
  const rows = $('rooms');
  rows.textContent = '';
  for (const room of body.rooms || []) {
    const tr = document.createElement('tr');
    for (const text of [
      room.roomId,
      room.template,
      room.status,
      room.peers + '/' + room.capacity,
      fmtAge(room.ageSeconds),
    ]) {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    }
    rows.appendChild(tr);
  }
}

async function loadAdmins() {
  const { body } = await api('/panel/api/admins');
  const rows = $('admins');
  rows.textContent = '';
  for (const admin of body.admins || []) {
    const tr = document.createElement('tr');
    if (admin.revokedAt) tr.className = 'revoked-row';
    const didCell = document.createElement('td');
    didCell.className = 'did';
    const code = document.createElement('code');
    code.textContent = admin.did;
    didCell.appendChild(code);
    if (admin.revokedAt) {
      const badge = document.createElement('span');
      badge.className = 'badge revoked';
      badge.textContent = 'revoked';
      didCell.appendChild(document.createTextNode(' '));
      didCell.appendChild(badge);
    }
    tr.appendChild(didCell);
    for (const text of [admin.addedByDid || '—', fmtDate(admin.createdAt)]) {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    }
    const action = document.createElement('td');
    if (admin.active) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'small';
      btn.textContent = 'Revoke';
      btn.addEventListener('click', () => revokeAdmin(admin.did));
      action.appendChild(btn);
    }
    tr.appendChild(action);
    rows.appendChild(tr);
  }
}

async function loadAudit() {
  const { body } = await api('/panel/api/audit');
  const rows = $('audit');
  rows.textContent = '';
  for (const entry of body.entries || []) {
    const tr = document.createElement('tr');
    for (const text of [
      fmtDate(entry.ts),
      entry.actorDid || '—',
      entry.action,
      entry.targetId ? (entry.targetType || '') + ' ' + entry.targetId : '—',
    ]) {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    }
    const details = document.createElement('td');
    details.className = 'details';
    if (entry.details && Object.keys(entry.details).length) {
      const code = document.createElement('code');
      code.textContent = JSON.stringify(entry.details);
      details.appendChild(code);
    } else {
      details.textContent = '—';
    }
    tr.appendChild(details);
    rows.appendChild(tr);
  }
}

async function revokeKey(id, label) {
  if (!confirm('Revoke key "' + label + '"? Games using it stop working immediately.')) return;
  const { status, body } = await api('/panel/api/keys/' + id + '/revoke', { method: 'POST' });
  if (status === 200) loadKeys();
  else alert(((body.error || {}).message) || 'revoke failed');
}

async function revokeAdmin(did) {
  if (!confirm('Revoke panel access for ' + did + '? They can be promoted again later.')) return;
  const { status, body } = await api(
    '/panel/api/admins/' + encodeURIComponent(did) + '/revoke', { method: 'POST' });
  if (status === 200 || status === 201) loadAdmins();
  else alert(((body.error || {}).message) || 'revoke failed');
}

$('create-key').addEventListener('submit', async (event) => {
  event.preventDefault();
  const label = $('label').value.trim();
  if (!label) return;
  const payload = { label };
  if (mode === 'postgres') {
    const rooms = $('max-rooms').value.trim();
    const templates = $('templates').value
      .split(',').map((t) => t.trim()).filter((t) => t.length > 0);
    if (rooms) payload.maxRooms = Number(rooms);
    if (templates.length) payload.templates = templates;
  }
  const { status, body } = await api('/panel/api/keys', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
  if (status !== 201) {
    alert(((body.error || {}).message) || 'create failed');
    return;
  }
  $('label').value = '';
  $('max-rooms').value = '';
  $('templates').value = '';
  $('new-key-value').textContent = body.key;
  $('new-key').classList.remove('hidden');
  loadKeys();
  if (mode === 'postgres') loadAudit();
});

$('promote-admin').addEventListener('submit', async (event) => {
  event.preventDefault();
  $('admin-err').classList.add('hidden');
  const didOrHandle = $('admin-input').value.trim();
  if (!didOrHandle) return;
  const { status, body } = await api('/panel/api/admins', {
    method: 'POST',
    body: JSON.stringify({ didOrHandle }),
  });
  if (status === 201) {
    $('admin-input').value = '';
    loadAdmins();
    if (mode === 'postgres') loadAudit();
    return;
  }
  $('admin-err').textContent = ((body.error || {}).message) || 'promote failed';
  $('admin-err').classList.remove('hidden');
});

$('copy-key').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText($('new-key-value').textContent);
    $('copy-key').textContent = 'Copied';
  } catch {
    $('copy-key').textContent = 'Select and copy';
  }
});

$('refresh').addEventListener('click', loadRooms);
$('refresh-audit').addEventListener('click', loadAudit);

// Pure decision for the sign-in poll loop. No DOM, no network — the
// served source of this exact function is unit-tested under node (see
// panel_test.dart): the server's flow state is the ONLY signal, so a
// lying popup closed flag can never turn a pending flow into a failure.
// status: HTTP status of /panel/api/auth/result (0 = no answer yet).
// Returns 'complete' | 'terminal' | 'timeout' | 'keep'.
function pollAction(status, elapsedMs, expiresInMs) {
  if (status === 200) return 'complete';
  if (status === 410) return 'terminal';
  if (elapsedMs >= expiresInMs) return 'timeout';
  return 'keep';
}

$('signin').addEventListener('submit', async (event) => {
  event.preventDefault();
  $('signin-err').classList.add('hidden');
  const handle = $('handle').value.trim();
  if (!handle) return;
  const start = await api('/panel/api/auth/start?handle=' + encodeURIComponent(handle));
  if (start.status !== 200) {
    $('signin-err').textContent =
      (((start.body || {}).error || {}).message) || 'could not start sign-in';
    $('signin-err').classList.remove('hidden');
    return;
  }
  const popup = window.open(start.body.authorizationUrl, 'openfire-signin',
    'width=480,height=720');
  if (!popup) {
    $('signin-err').textContent = 'popup blocked — allow popups for this site, or start again';
    $('signin-err').classList.remove('hidden');
    return;
  }
  const flow = start.body.flow;
  const expiresInMs = Number(start.body.expiresInMs) || 0;
  // NOTE: the popup's closed property is deliberately never read below.
  // For popups that navigate cross-origin (about:blank → bsky.social) it
  // can report true while the window is provably open (verified via
  // CDP), which killed every live sign-in ~1–2 s in. The flow state on
  // the server is authoritative; the popup reference is kept only to
  // close the window after a successful sign-in.
  $('signin-btn').disabled = true;
  $('signin-wait').classList.remove('hidden');
  const finish = await new Promise((resolve) => {
    const startedAt = Date.now();
    const cancel = $('signin-cancel');
    const settle = (value) => {
      cancel.removeEventListener('click', onCancel);
      resolve(value);
    };
    const onCancel = () => settle({ ok: false, cancelled: true });
    cancel.addEventListener('click', onCancel);
    const poll = async () => {
      // Expired with no completion (checked before each request too,
      // so the loop can never outlive the server's flow TTL).
      if (pollAction(0, Date.now() - startedAt, expiresInMs) === 'timeout') {
        return settle({ ok: false, timedOut: true });
      }
      var status = 0;
      try {
        const result = await api('/panel/api/auth/result?flow=' + encodeURIComponent(flow));
        status = result.status;
        const action = pollAction(status, Date.now() - startedAt, expiresInMs);
        if (action === 'complete') return settle({ ok: true, body: result.body });
        if (action === 'terminal') {
          // The flow failed terminally; the server says why — show the
          // real reason instead of a generic retry hint.
          const message = (((result.body || {}).error || {}).message) ||
            (((result.body || {}).error || {}).code) || 'sign-in failed';
          return settle({ ok: false, message });
        }
      } catch (_) {
        // Transient network error — the decision below keeps polling
        // until the TTL lapses, then times out like any other silence.
      }
      if (pollAction(status, Date.now() - startedAt, expiresInMs) === 'timeout') {
        return settle({ ok: false, timedOut: true });
      }
      setTimeout(poll, 500);
    };
    poll();
  });
  $('signin-wait').classList.add('hidden');
  $('signin-btn').disabled = false;
  if (finish.ok && finish.body.session) popup.close();
  if (finish.cancelled) {
    $('signin-err').textContent = 'sign-in cancelled — start again';
    $('signin-err').classList.remove('hidden');
    return;
  }
  if (finish.timedOut) {
    $('signin-err').textContent = 'sign-in window timed out — start again';
    $('signin-err').classList.remove('hidden');
    return;
  }
  if (!finish.ok) {
    $('signin-err').textContent = finish.message;
    $('signin-err').classList.remove('hidden');
    return;
  }
  if (!finish.body.session) {
    $('signin-err').textContent = 'sign-in did not complete — try again';
    $('signin-err').classList.remove('hidden');
    return;
  }
  session = finish.body.session;
  localStorage.setItem(SESSION_KEY, session);
  init();
});

init();
''';
