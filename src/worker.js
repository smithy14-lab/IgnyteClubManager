// Cloudflare Worker in front of the static assets: pretty club-site URLs.
// /c/{slug} and /c/{slug}/{page} serve the /club page, which reads the club
// slug and page from the path and renders that club's website.
const PLATFORM_HOSTS = ['ignyte-club-manager.nathansmith00.workers.dev', 'localhost', '127.0.0.1'];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (/^\/c\/[a-z0-9-]+(\/[a-z0-9-]+)?\/?$/.test(url.pathname)) {
      url.pathname = '/club/';
      return env.ASSETS.fetch(new Request(url.toString(), request));
    }
    // Custom club domains: the whole host is the club's website. Root and
    // single-segment paths render the club site (client resolves host->slug);
    // asset paths pass through untouched.
    if (!PLATFORM_HOSTS.includes(url.hostname) && /^\/([a-z0-9-]+\/?)?$/.test(url.pathname)) {
      const seg = url.pathname.replaceAll('/', '');
      // login/join/signup render the CLUB'S branded front door on its domain
      const appPages = ['dashboard', 'welcome', 'clubs', 'start', 'offline'];
      if (!appPages.includes(seg)) {
        url.pathname = '/club/';
        return env.ASSETS.fetch(new Request(url.toString(), request));
      }
    }
    return env.ASSETS.fetch(request);
  },
};
