// Cloudflare Worker in front of the static assets: pretty club-site URLs.
// /c/{slug} and /c/{slug}/{page} serve the /club page, which reads the club
// slug and page from the path and renders that club's website.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (/^\/c\/[a-z0-9-]+(\/[a-z0-9-]+)?\/?$/.test(url.pathname)) {
      url.pathname = '/club/';
      return env.ASSETS.fetch(new Request(url.toString(), request));
    }
    return env.ASSETS.fetch(request);
  },
};
