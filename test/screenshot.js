// test/screenshot.js: capture a store-listing screenshot of a running
// Endurain install.
//
// Endurain's frontend is a Vue single-page application, so chromium's plain
// --screenshot flag captures its empty shell: the load event fires long
// before the application has fetched anything and drawn itself.
// --virtual-time-budget does not help and can make it worse, because it
// advances virtual time while real network work is still outstanding. The
// only reliable approach is to drive a real browser and wait for content
// that only exists once the application has actually rendered.
//
// Usage, from the package root:
//
//   podman run --rm --network=host --userns=keep-id \
//     -v "$PWD":/work:z -w /work \
//     -e NODE_PATH=/usr/src/app/node_modules \
//     -e ENDURAIN_USER=admin -e ENDURAIN_PASSWORD='...' \
//     docker.io/zenika/alpine-chrome:with-puppeteer \
//     node test/screenshot.js https://app.example.com /work/docs/screenshot.png
//
// --userns=keep-id is load-bearing: without it chromium runs fine and only
// the file write fails, with a permission error that reads like a chromium
// fault rather than a mount-ownership one. NODE_PATH is required because
// puppeteer lives at /usr/src/app/node_modules in that image and node
// resolves modules relative to the script, which is bind-mounted elsewhere.
//
// The credentials come from the environment, never from argv, so they do not
// appear in the container's command line where `ps` would show them. Signing
// in is optional: with no credentials set, the public login page is captured,
// which is itself a reasonable listing image because it shows the single
// sign-on button this package provisions.

const puppeteer = require('puppeteer-core');

const [url, out] = [process.argv[2], process.argv[3]];
const user = process.env.ENDURAIN_USER || '';
const password = process.env.ENDURAIN_PASSWORD || '';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/chromium-browser',
    args: ['--no-sandbox', '--disable-gpu', '--hide-scrollbars'],
    defaultViewport: { width: 1280, height: 800 },
  });
  const page = await browser.newPage();

  await page.goto(url, { waitUntil: 'networkidle2', timeout: 120000 });

  // The application is rendered once the root container has real children.
  // Checking for #app alone is not enough: it exists in the served HTML
  // before any JavaScript has run, so it would match the blank shell.
  try {
    await page.waitForFunction(
      () => {
        const app = document.querySelector('#app');
        return app && app.children.length > 0 && document.body.innerText.trim().length > 0;
      },
      { timeout: 90000 },
    );
  } catch (e) {
    console.error('render wait timed out, capturing whatever is there');
  }

  if (user && password) {
    try {
      // Fill by input type rather than by a framework-generated id or class,
      // which change between releases and would silently stop matching.
      await page.waitForSelector('input[type="password"]', { timeout: 30000 });
      const textInput = await page.$('input[type="text"]') || await page.$('input:not([type="password"])');
      if (textInput) {
        await textInput.click({ clickCount: 3 });
        await textInput.type(user);
      }
      const pwInput = await page.$('input[type="password"]');
      await pwInput.click({ clickCount: 3 });
      await pwInput.type(password);

      await Promise.all([
        page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 60000 }).catch(() => {}),
        page.keyboard.press('Enter'),
      ]);

      // Signed in means the password field is gone and content has replaced it.
      await page.waitForFunction(
        () => !document.querySelector('input[type="password"]'),
        { timeout: 60000 },
      );
    } catch (e) {
      console.error('sign-in did not complete, capturing the page as it stands:', e.message);
    }
  }

  // Wait for map tiles specifically, not just for a fixed interval. The
  // activity cards render their route immediately over an empty background
  // and the tile images arrive afterwards from the tile server, so a capture
  // taken on a timer alone shows a coloured rectangle with a line on it and
  // no map underneath. Waiting for the tile images to report complete gives
  // the listing image an actual map. Falls through on timeout rather than
  // failing, because a tile server being slow or unreachable should still
  // produce a screenshot.
  try {
    await page.waitForFunction(
      () => {
        const tiles = Array.from(document.querySelectorAll('img')).filter(
          (i) => /tile|openstreetmap|stadiamaps/i.test(i.src || ''),
        );
        return tiles.length > 0 && tiles.every((i) => i.complete && i.naturalWidth > 0);
      },
      { timeout: 45000 },
    );
  } catch (e) {
    console.error('map tiles did not all load, capturing anyway');
  }

  // Let charts and any remaining lazy images settle.
  await sleep(Number(process.env.SETTLE_MS || 6000));
  await page.screenshot({ path: out });
  console.error('captured to', out);
  await browser.close();
})();
