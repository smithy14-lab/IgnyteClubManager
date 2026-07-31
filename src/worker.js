// Cloudflare Worker in front of the static assets: pretty club-portal URLs.
// /c/{slug} serves the /club page (which reads the slug from the path).
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (/^\/c\/[a-z0-9-]+\/?$/.test(url.pathname)) {
      url.pathname = '/club/';
      return env.ASSETS.fetch(new Request(url.toString(), request));
    }
    return env.ASSETS.fetch(request);
  },
};
