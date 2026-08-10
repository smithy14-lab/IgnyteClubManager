// Stamp the service worker cache version with the build time so every deploy
// invalidates old shell/asset caches on clients (installed PWAs included).
import { readFileSync, writeFileSync } from 'node:fs';
const path = new URL('../dist/sw.js', import.meta.url);
const stamp = `v${new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 12)}`;
const src = readFileSync(path, 'utf8');
writeFileSync(path, src.replace(/const VERSION = '[^']+';/, `const VERSION = '${stamp}';`));
console.log(`sw.js stamped ${stamp}`);
