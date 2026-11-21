#!/usr/bin/env node
// Export the same guides and reference documents used in the static site.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const site = fileURLToPath(new URL('../', import.meta.url));
const docsDir = path.join(site, 'src/content/docs/docs');
const guides = [
  'index.mdx', 'hosted.md', 'multiplayer-server.md', 'self-hosting.md', 'panel.md',
  'shared-state-rooms.md', 'physics-rooms.md', 'voice-chat.md', 'how-it-works.md', 'protocol-clients.mdx',
  'accounts.md', 'identity-ladder.md', 'where-accounts-live.md',
  'api.mdx', 'templates.mdx', 'protocol.mdx', 'identity.mdx',
];

function readGuide(file) {
  const source = readFileSync(path.join(docsDir, file), 'utf8');
  const [, metadata, content] = source.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  const title = metadata.match(/^title: (.+)$/m)[1];
  const description = metadata.match(/^description: (.+)$/m)[1];
  const slug = path.parse(file).name;
  const url = slug === 'index' ? '/docs/' : `/docs/${slug}/`;
  let body = content;
  const reference = body.match(/^import \{ Content as (\w+) \} from '([^']+)';$/m);
  if (reference) {
    const markdown = readFileSync(path.resolve(docsDir, reference[2]), 'utf8');
    body = body.replace(reference[0], '').replace(`<${reference[1]} />`, () => markdown.replace(/^# [^\n]+\n/, ''));
  }
  body = body.replace(/^<(?:span id=|div class=|script src=).*$/gm, '').trim();
  return { title, description, url, body };
}

const pages = guides.map(readGuide);
const index = pages.map(({ title, description, url }) => `- [${title}](${url}) — ${description}`);
const specs = [
  '- [Wire protocol as JSON](/spec/rooms-protocol.json)',
  '- [RoomAuthority interface](/spec/room-authority.md)',
  '- [Full documentation](/llms-full.txt)',
];

writeFileSync(path.join(site, 'public/llms.txt'), [
  '# Livefire', '', 'Multiplayer rooms over HTTP and WebSocket.', '',
  ...index, '', '## Specifications', '', ...specs, '',
].join('\n'));
const authority = readFileSync(path.join(site, 'public/spec/room-authority.md'), 'utf8');
writeFileSync(path.join(site, 'public/llms-full.txt'), [
  '# Livefire documentation', '', ...index, '',
  ...pages.map(({ title, body }) => `# ${title}\n\n${body}\n`), authority,
].join('\n'));
