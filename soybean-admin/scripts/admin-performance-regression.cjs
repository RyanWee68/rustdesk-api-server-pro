// 使用独立浏览器检查登录页离线图标和低开销默认渲染，不连接真实账号。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

/** 验证正式构建在桌面和移动视口下无需外部图标服务。 */
async function main() {
  const root = path.resolve(process.argv[2]);
  const types = { '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.html': 'text/html' };
  const server = http.createServer((req, res) => {
    const pathname = new URL(req.url, 'http://localhost').pathname;
    if (pathname.startsWith('/admin/')) {
      const data = pathname.endsWith('/providers') ? [] : { captchaEnabled: false };
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ code: 200, message: '', data }));
      return;
    }
    const filename = path.resolve(root, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!filename.startsWith(root + path.sep) || !fs.existsSync(filename)) {
      res.writeHead(404).end();
      return;
    }
    res.setHeader('Content-Type', types[path.extname(filename)] || 'application/octet-stream');
    fs.createReadStream(filename).pipe(res);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  let browser;
  try {
    browser = await chromium.launch({ headless: true, channel: 'msedge' });
    for (const viewport of [{ width: 1920, height: 1080 }, { width: 390, height: 844 }]) {
      const context = await browser.newContext({ viewport });
      const page = await context.newPage();
      const external = [];
      const errors = [];
      await page.route('**/*', route => {
        if (!route.request().url().startsWith(origin + '/')) {
          external.push(route.request().url());
          return route.abort();
        }
        return route.continue();
      });
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(origin, { waitUntil: 'networkidle' });
      await page.locator('input').first().fill('latency-fixture');
      assert.equal(await page.locator('input').first().inputValue(), 'latency-fixture');
      assert.equal(await page.locator('html.glass-effect').count(), 0);
      assert.equal(await page.locator('.login-card').evaluate(el => getComputedStyle(el).backdropFilter), 'none');
      assert.notEqual(await page.locator('.login-card').evaluate(el => getComputedStyle(el).backgroundColor), 'rgba(0, 0, 0, 0)');
      assert.ok(await page.locator('.login-card svg[viewBox]').count() >= 3, 'ERR-1019: 登录页本地图标未渲染');
      assert.deepEqual(external, [], 'ERR-1019: 页面仍依赖外部请求');
      assert.deepEqual(errors, [], 'ERR-1019: 页面存在脚本错误');
      console.log(`登录页回归通过：${viewport.width}x${viewport.height}，外部请求 0`);
      await context.close();
    }
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
