const fs = require('fs');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
(async () => {
  const base = 'profiles/fastacl-v9/root/usr/lib/lua/luci/view/juliang_fastacl/';
  const clean = text => text.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '').replace(/<%[\s\S]*?%>/g, '');
  const html = clean(fs.readFileSync(base + 'console.htm', 'utf8')) + clean(fs.readFileSync(base + 'batch_wifi.htm', 'utf8'));
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.setContent(html);
    const nodes = page.locator('#jfa_nodes_panel');
    const batch = page.locator('#jfw_panel');
    assert.equal(await nodes.evaluate(el => el.open), true);
    assert.equal(await batch.evaluate(el => el.open), false);
    assert.equal(await page.locator('#jfa_body').isVisible(), true);
    assert.equal(await page.locator('#jfw_prefix').isVisible(), false);
    await nodes.locator('summary').click();
    assert.equal(await page.locator('#jfa_body').isVisible(), false);
    await nodes.locator('summary').click();
    assert.equal(await page.locator('#jfa_body').isVisible(), true);
    await batch.locator('summary').click();
    assert.equal(await page.locator('#jfw_prefix').isVisible(), true);
    assert.equal(await batch.locator('.jfw-collapse').isVisible(), true);
    await batch.locator('summary').click();
    assert.equal(await page.locator('#jfw_prefix').isVisible(), false);
    await nodes.locator('summary').focus();
    await page.keyboard.press('Enter');
    assert.equal(await nodes.evaluate(el => el.open), false);
    await page.keyboard.press('Enter');
    assert.equal(await nodes.evaluate(el => el.open), true);
    await page.setViewportSize({width:390, height:844});
    await batch.locator('summary').click();
    assert.equal(await page.locator('#jfw_prefix').isVisible(), true);
    console.log('PASS: defaults, collapse/expand, labels, keyboard, mobile viewport');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

