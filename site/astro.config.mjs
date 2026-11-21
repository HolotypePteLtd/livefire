import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Reference pages supply their own title when they embed a repository document.
const referenceDir = fileURLToPath(new URL('../docs', import.meta.url));
function omitEmbeddedTitle() {
  return (tree, file) => {
    const first = tree.children[0];
    if (file.path && dirname(file.path) === referenceDir && first?.type === 'heading' && first.depth === 1) {
      tree.children.shift();
    }
  };
}

export default defineConfig({
  markdown: { remarkPlugins: [omitEmbeddedTitle] },
  site: process.env.SITE_URL ?? 'https://rooms-sdk-docs.pages.dev',
  trailingSlash: 'ignore',
  redirects: {
    '/docs/concepts': '/docs/how-it-works/',
    '/docs/getting-started': '/docs/multiplayer-server/',
    '/docs/recipes/chat': '/docs/multiplayer-server/',
    '/docs/recipes/put-my-game-online': '/docs/multiplayer-server/',
    '/docs/recipes/shared-state': '/docs/shared-state-rooms/',
    '/docs/recipes/movement-game': '/docs/physics-rooms/',
    '/docs/movement-rooms': '/docs/physics-rooms/',
    '/docs/recipes/bluesky-signin': '/docs/accounts/',
  },
  build: { inlineStylesheets: 'never' },
  integrations: [
    starlight({
      title: 'Livefire',
      description: 'Run a multiplayer server, build a game client, and manage player accounts.',
      favicon: '/favicon.svg',
      routeMiddleware: './src/reference-nav.ts',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/HolotypePteLtd/livefire' }],
      customCss: ['/src/styles/starlight.css'],
      expressiveCode: {
        themes: ['github-dark', 'github-light'],
        defaultProps: { frame: 'none' },
      },
      sidebar: [
        { label: 'Guides', items: [
          { label: 'Documentation', link: '/docs/' },
          { label: 'Hosted quickstart', link: '/docs/hosted/' },
          { label: 'Run a room', link: '/docs/multiplayer-server/' },
          { label: 'Self-host Livefire', link: '/docs/self-hosting/' },
          { label: 'Developer panel', link: '/docs/panel/' },
        ] },
        { label: 'Rooms', items: [
          { label: 'Shared state rooms', link: '/docs/shared-state-rooms/' },
          { label: 'Physics rooms', link: '/docs/physics-rooms/' },
          { label: 'Voice chat and spatial audio', link: '/docs/voice-chat/' },
          { label: 'How rooms work', link: '/docs/how-it-works/' },
          { label: 'Write a WebSocket client', link: '/docs/protocol-clients/' },
        ] },
        { label: 'Player accounts', items: [
          { label: 'Enable sign-in', link: '/docs/accounts/' },
          { label: 'Use an existing PDS', link: '/docs/self-hosting/#already-run-a-pds' },
          { label: 'Device accounts and recovery', link: '/docs/identity-ladder/' },
          { label: 'Where accounts live', link: '/docs/where-accounts-live/' },
        ] },
        { label: 'Reference', items: [
          { label: 'HTTP API', link: '/docs/api/' },
          { label: 'Room templates', link: '/docs/templates/' },
          { label: 'Wire protocol', link: '/docs/protocol/' },
          { label: 'Identity', link: '/docs/identity/' },
          { label: 'RoomAuthority interface', link: '/spec/room-authority.md' },
          { label: 'Documentation index (text)', link: '/llms.txt' },
        ] },
      ],
    }),
  ],
});
