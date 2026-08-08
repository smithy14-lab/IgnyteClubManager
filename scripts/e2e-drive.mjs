// Ignyte Club Manager — live end-to-end test drive.
// Drives the LIVE site headless, screenshotting every step into e2e-shots/
// and writing running notes to e2e-notes.md. Run in stages so the operator
// (or Claude) can do database-side steps between them:
//
//   node scripts/e2e-drive.mjs stage1   # founder signs up a club (TESTDRIVE)
//   node scripts/e2e-drive.mjs stage2   # coach account: login + coaching hub
//   node scripts/e2e-drive.mjs stage3   # family joins at club link, books
//
// Preconditions: Supabase "Confirm email" OFF, Site URL set to the app URL.
// Stage 2 expects the coach password to be set (invite normally does this
// via the emailed /welcome link; in headless testing it's set directly).

import { chromium } from 'playwright-core';
import fs from 'node:fs';

const BASE = process.env.APP_URL ?? 'https://ignyte-club-manager.nathansmith00.workers.dev';
const CHROME = process.env.CHROME ?? '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const STAGE = process.argv[2] ?? 'stage1';
const PW = 'TestDrive123!';
const CLUB = { name: 'Blaze Cheer Academy', slug: 'blaze-cheer-academy' };
const EMAILS = {
  founder: 'smithy.ns83+club@gmail.com',
  coach: 'smithy.ns83+coach@gmail.com',
  family: 'smithy.ns83+family@gmail.com',
};

fs.mkdirSync('e2e-shots', { recursive: true });
const notes = [];
const note = (s) => {
  notes.push(`- ${new Date().toISOString().slice(11, 19)} ${s}`);
  console.log(s);
};
let shotN = 0;
const save = () =>
  fs.appendFileSync('e2e-notes.md', `\n## ${STAGE} — ${new Date().toISOString()}\n${notes.join('\n')}\n`);

async function main() {
  const browser = await chromium.launch({ executablePath: CHROME });
  const page = await browser.newPage({ viewport: { width: 1280, height: 850 } });
  const shot = async (name) => {
    shotN++;
    const f = `e2e-shots/${STAGE}-${String(shotN).padStart(2, '0')}-${name}.png`;
    await page.screenshot({ path: f, fullPage: false });
    note(`📸 ${f}`);
  };
  const toastText = async () => {
    const t = page.locator('.toast, [class*="toast"]').last();
    return (await t.isVisible().catch(() => false)) ? (await t.textContent())?.trim() : null;
  };

  try {
    if (STAGE === 'stage1') {
      note(`Opening ${BASE}`);
      await page.goto(BASE, { waitUntil: 'load', timeout: 30000 });
      await shot('home');

      await page.goto(`${BASE}/start`, { waitUntil: 'load' });
      await page.waitForTimeout(1500);
      note('Filling founder signup (account + club + promo)…');
      await page.fill('#w-yourname', 'Nathan Test');
      await page.fill('#w-email', EMAILS.founder);
      await page.fill('#w-pw', PW);
      await page.fill('#w-name', CLUB.name);
      await page.fill('#w-loc', 'Blaze Gym');
      await page.fill('#w-promo', 'TESTDRIVE');
      await page.locator('#w-promo').blur();
      await page.waitForTimeout(1200);
      const promoMsg = await page.locator('#w-promo-msg').textContent().catch(() => '');
      note(`Promo check says: "${promoMsg?.trim()}"`);
      await shot('start-filled');

      await page.click('#w-go');
      await page.waitForTimeout(5000);
      const done = await page.locator('#done').isVisible().catch(() => false);
      const confirmNote = await page.locator('#confirm-note').isVisible().catch(() => false);
      note(done ? '✅ Club created — live screen shown' : confirmNote ? '⚠️ Stopped at email confirmation (turn Confirm email off)' : `❓ Unexpected state. Toast: ${await toastText()}`);
      await shot(done ? 'club-live' : 'club-not-done');

      if (done) {
        await page.goto(`${BASE}/admin/website`, { waitUntil: 'load' });
        await page.waitForTimeout(2500);
        await shot('admin-website');
        note('Publishing an About page…');
        const newCard = page.locator('[data-pagecard=""]');
        await newCard.locator('[data-f="title"]').fill('About us');
        await newCard.locator('[data-f="slug"]').fill('about');
        await newCard.locator('[data-f="body"]').fill('# Welcome to Blaze\n\nWe are a **test** cheer academy.');
        await newCard.locator('[data-saveclass], [data-save=""], [data-saveprod=""], button:has-text("Add page")').first().click();
        await page.waitForTimeout(2000);
        await shot('page-added');

        note('Inviting the coach from Admin → Import…');
        await page.goto(`${BASE}/admin/import`, { waitUntil: 'load' });
        await page.waitForTimeout(2500);
        await page.fill('#c-name', 'Casey Coach');
        await page.fill('#c-email', EMAILS.coach);
        await shot('import-filled');
        await page.click('#c-go');
        await page.waitForTimeout(4000);
        note(`Invite result toast: ${await toastText()}`);
        await shot('coach-invited');
      }
    }

    if (STAGE === 'stage2') {
      note('Signing in as the coach…');
      await page.goto(`${BASE}/login`, { waitUntil: 'load' });
      await page.waitForTimeout(1500);
      await page.fill('#email, input[type="email"]', EMAILS.coach);
      await page.fill('#password, input[type="password"]', PW);
      await page.locator('button[type="submit"]').first().click();
      await page.waitForTimeout(4000);
      await shot('coach-signed-in');
      await page.goto(`${BASE}/coach`, { waitUntil: 'load' });
      await page.waitForTimeout(3000);
      await shot('coaching-hub');
      note('Coach can see the Coaching hub.');
    }

    if (STAGE === 'stage3') {
      note(`Visiting the club website /c/${CLUB.slug}…`);
      await page.goto(`${BASE}/c/${CLUB.slug}`, { waitUntil: 'load' });
      await page.waitForTimeout(2500);
      await shot('club-website');
      await page.goto(`${BASE}/c/${CLUB.slug}/join`, { waitUntil: 'load' });
      await page.waitForTimeout(2000);
      await shot('branded-join');
      note('Signing up as a family via the branded join page…');
      await page.fill('#a-name', 'Fran Family');
      await page.fill('#a-email', EMAILS.family);
      await page.fill('#a-pw', PW);
      await page.locator('#auth-form button[type="submit"]').click();
      await page.waitForTimeout(5000);
      await shot('family-joined');
      note('Adding an athlete…');
      await page.goto(`${BASE}/athletes`, { waitUntil: 'load' });
      await page.waitForTimeout(2500);
      await page.fill('#name', 'Alfie Family');
      await page.fill('#dob', '2016-05-05');
      await page.locator('#add-form button[type="submit"]').click();
      await page.waitForTimeout(3000);
      await shot('athlete-added');
      await page.goto(`${BASE}/book`, { waitUntil: 'load' });
      await page.waitForTimeout(3000);
      await shot('book-page');
      note('Stage 3 done — booking screen reached (slot booking depends on slots existing).');
    }
  } catch (e) {
    note(`❌ FAILED: ${e.message.slice(0, 300)}`);
    await shot('failure');
  } finally {
    save();
    await browser.close();
  }
}
main();
