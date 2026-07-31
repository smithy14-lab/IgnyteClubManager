// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

// Fully static output — every page is an app shell that talks to Supabase
// from the browser, so the site deploys to any free static host (Netlify,
// Cloudflare Pages, Azure Static Web Apps, GitHub Pages...).
export default defineConfig({
  output: 'static',
  trailingSlash: 'ignore',
  vite: {
    plugins: [tailwindcss()],
  },
});
