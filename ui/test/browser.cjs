// Test-only browser automation; no JavaScript application bundle is built.
// Requires Playwright in the test runner's module path.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const base = process.env.UI_TEST_URL || 'http://127.0.0.1:8081';
(async () => {
  const browser = await chromium.launch({headless:true, args:['--no-sandbox']});
  try {
    const context = await browser.newContext();
    const errors = [];
    // Test that framework assets don't require a CDN.
    await context.route('**/*', route => new URL(route.request().url()).origin === new URL(base).origin
      ? route.continue() : route.abort());
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(base + '/studies');
    await page.locator('a.mm-card').first().waitFor({timeout:30000});
    assert.equal(await page.locator('a.mm-card').count(), 2);
    assert.match(await page.locator('body').innerText(), /DEMO DATA/);
    await page.getByRole('button', {name:'Refresh', exact:true}).click();
    await page.waitForFunction(() => document.querySelectorAll('a.mm-card').length === 2);
    await page.locator('a.mm-card').filter({hasText:'fixture_coastal'}).click();
    await page.getByText('run_A', {exact:true}).waitFor();
    assert.equal(await page.locator('h1').innerText(), 'fixture_coastal');
    await page.reload();
    await page.getByText('run_B', {exact:true}).waitFor();
    const second = await context.newPage();
    await second.goto(base + '/studies/fixture_empty');
    await second.getByText('No direct runs.', {exact:true}).waitFor();
    assert.equal(await page.locator('h1').innerText(), 'fixture_coastal');
    await second.goto(base + '/studies/missing');
    await second.getByRole('alert').waitFor();
    assert.match(await second.getByRole('alert').innerText(), /not found/);
    await second.goto(base + '/studies/malformed');
    await second.getByRole('alert').waitFor();
    assert.match(await second.getByRole('alert').innerText(), /contract/);
    await page.getByRole('link', {name:'All studies'}).click();
    await page.locator('a.mm-card').first().waitFor();
    assert.deepEqual(errors, []);
    console.log('PASS: list, refresh, navigation, direct load/reload, independent tabs, missing/malformed data, local assets');
  } finally { await browser.close(); }
})().catch(e => {console.error(e); process.exit(1);});
