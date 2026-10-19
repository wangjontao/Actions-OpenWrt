await page.goto('http://127.0.0.1:8525/',{waitUntil:'domcontentloaded'});
await expect(page.locator('#f25-rows tr')).toHaveCount(3);
return await tabbit.observe({frames:'none',maxChars:4500});
