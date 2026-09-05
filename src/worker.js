// Cloudflare Worker in front of the static assets. Nothing clever: every
// page is an app shell that talks to Supabase from the browser.
export default {
  async fetch(request, env) {
    return env.ASSETS.fetch(request);
  },
};
