// Regenerates the PNG app icons from the brand mark (run: node scripts/generate-icons.mjs)
import sharp from 'sharp';

// Kept in sync with src/components/IgnyteMark.astro
const MARK = `
  <path fill="url(#g)" d="M28 8 h6 a5 5 0 0 1 5 5 v6 a5 5 0 0 1 -5 5 h-6 a5 5 0 0 1 -5 -5 v-6 a5 5 0 0 1 5 -5 Z M66 8 h6 a5 5 0 0 1 5 5 v6 a5 5 0 0 1 -5 5 h-6 a5 5 0 0 1 -5 -5 v-6 a5 5 0 0 1 5 -5 Z"/>
  <path fill="url(#g)" fill-rule="evenodd" d="M26 20 H74 A16 16 0 0 1 90 36 V74 A16 16 0 0 1 74 90 H26 A16 16 0 0 1 10 74 V36 A16 16 0 0 1 26 20 Z M57 28 L35 60 L49 60 L43 84 L67 50 L53 50 Z"/>
  <path fill="url(#g)" d="M91 4 L94 10.5 L91 17 L88 10.5 Z"/>`;

const GRADIENT = `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0%" stop-color="#ffc23d"/><stop offset="45%" stop-color="#ff6a1a"/><stop offset="100%" stop-color="#ff1f8e"/>
</linearGradient></defs>`;

function iconSvg(canvas, markScale) {
  const m = canvas * markScale;
  const off = (canvas - m) / 2;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${canvas}" height="${canvas}">
    ${GRADIENT}
    <rect width="${canvas}" height="${canvas}" fill="#07070b"/>
    <svg x="${off}" y="${off}" width="${m}" height="${m}" viewBox="0 0 100 100">${MARK}</svg>
  </svg>`;
}

const jobs = [
  ['public/icon-512.png', 512, 0.68],
  ['public/icon-192.png', 192, 0.68],
  ['public/apple-touch-icon.png', 180, 0.68],
  ['public/favicon-32.png', 32, 0.9],
];
for (const [file, size, scale] of jobs) {
  await sharp(Buffer.from(iconSvg(size, scale))).png().toFile(file);
  console.log('✓', file);
}
