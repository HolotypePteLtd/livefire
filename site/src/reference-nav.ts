import { defineRouteMiddleware } from '@astrojs/starlight/route-data';
import { getHeadings as api } from '../../docs/control_plane_api.md';
import { getHeadings as identity } from '../../docs/identity.md';
import { getHeadings as protocol } from '../../docs/protocol.md';
import { getHeadings as templates } from '../../docs/room_templates.md';

// Starlight indexes a guide's own headings. Include sections from embedded Markdown too.
const references = new Map([
  ['docs/api', api],
  ['docs/identity', identity],
  ['docs/protocol', protocol],
  ['docs/templates', templates],
]);

export const onRequest = defineRouteMiddleware(({ locals }) => {
  const { entry, toc } = locals.starlightRoute;
  const headings = references.get(entry.id);
  if (toc && headings) {
    for (const heading of headings()) {
      if (heading.depth === 2) toc.items.push({ ...heading, children: [] });
    }
  }
});
