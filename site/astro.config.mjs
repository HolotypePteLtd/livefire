import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// SITE is only used to build canonical URLs (sitemap); override per
// deployment if you care. The build is plain static files either way.
export default defineConfig({
  site: process.env.SITE_URL ?? 'https://rooms.example.com',
  trailingSlash: 'ignore',
  // Old URLs keep working: recipes + getting-started were consolidated into
  // the outcome-led pages (see the task brief's IA overhaul).
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
  // Emit every stylesheet as a hashed /_astro/*.css asset instead of letting
  // Astro inline small ones — keeps CSP deployable and the built HTML free
  // of surprises when auditing asset references.
  build: { inlineStylesheets: 'never' },
  integrations: [
    starlight({
      title: 'Openfire',
      description:
        'Authoritative multiplayer rooms, realtime chat and server-side physics over an open wire protocol.',
      favicon: '/favicon.svg',
      customCss: ['/src/styles/starlight.css'],
      // Code blocks: bake the theme colors in at build time (this is the
      // supported channel; the CSS vars in starlight.css only back them up).
      expressiveCode: {
        styleOverrides: {
          borderWidth: '1px',
          borderColor: '#242B3A',
          codeBackground: '#12151D',
          codeForeground: '#EDF1F7',
          codeSelectionBackground: '#2A3247',
          gutterBorderColor: '#242B3A',
          gutterForeground: '#74809A',
          focusBorder: '#F5A54A',
        },
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', link: '/docs/' },
            {
              label: 'Instant multiplayer server',
              link: '/docs/multiplayer-server/',
            },
          ],
        },
        {
          label: 'Room types',
          items: [
            {
              label: 'Shared state rooms',
              link: '/docs/shared-state-rooms/',
            },
            { label: 'Physics rooms', link: '/docs/physics-rooms/' },
            { label: 'Player accounts', link: '/docs/accounts/' },
            { label: 'Identity ladder', link: '/docs/identity-ladder/' },
          ],
        },
        {
          label: 'How it works',
          items: [{ label: 'How it works', link: '/docs/how-it-works/' }],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Wire protocol', link: '/docs/protocol/' },
            { label: 'Writing a client in any language', link: '/docs/protocol-clients/' },
            { label: 'Room templates', link: '/docs/templates/' },
            { label: 'Rooms server HTTP API', link: '/docs/api/' },
            { label: 'Developer panel', link: '/docs/panel/' },
            { label: 'Identity', link: '/docs/identity/' },
            {
              label: 'Where accounts live',
              link: '/docs/where-accounts-live/',
            },
            { label: 'Self-hosting', link: '/docs/self-hosting/' },
          ],
        },
        {
          label: 'For coding agents',
          items: [
            { label: 'llms.txt', link: '/llms.txt' },
            { label: 'llms-full.txt', link: '/llms-full.txt' },
            { label: 'rooms-protocol.json', link: '/spec/rooms-protocol.json' },
            { label: 'room-authority.md', link: '/spec/room-authority.md' },
          ],
        },
      ],
    }),
  ],
});
