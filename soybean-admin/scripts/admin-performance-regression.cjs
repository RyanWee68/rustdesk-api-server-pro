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
      let data = pathname.endsWith('/providers') ? [] : { captchaEnabled: false };
      if (pathname === '/admin/userinfo') {
        data = { userId: '1', userName: 'fixture', roles: [req.headers.authorization === 'fixture-admin' ? 'R_SUPER' : 'R_USER'], buttons: [] };
      }
      if (pathname === '/admin/route/isRouteExist') data = true;
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
      await page.getByRole('button', { name: '客户端下载', exact: true }).click();
      for (const version of ['1.5.0', '1.4.9']) {
        assert.equal(await page.getByRole('link', { name: `RustDesk ${version} · Windows x64`, exact: true }).getAttribute('href'), `/downloads/rustdesk-${version}-x86_64.exe`);
      }
      assert.equal(await page.getByRole('link', { name: '下载证书', exact: true }).count(), 0);
      if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: path.join(process.env.SCREENSHOT_DIR, `downloads-login-${viewport.width}.png`), animations: 'disabled' });
      assert.deepEqual(external, [], 'ERR-1019: 页面仍依赖外部请求');
      assert.deepEqual(errors, [], 'ERR-1019: 页面存在脚本错误');
      console.log(`登录页回归通过：${viewport.width}x${viewport.height}，外部请求 0`);
      await context.close();
    }
    for (const role of ['admin', 'user']) {
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      await context.addInitScript(token => {
        localStorage.setItem('SOY_token', JSON.stringify(token));
      }, `fixture-${role}`);
      const page = await context.newPage();
      await page.goto(`${origin}/#/about/version`, { waitUntil: 'networkidle' });
      await page.getByRole('button', { name: '客户端下载', exact: true }).click();
      assert.equal(await page.getByRole('link', { name: 'RustDesk 1.5.0 · Windows x64', exact: true }).getAttribute('href'), '/downloads/rustdesk-1.5.0-x86_64.exe');
      await page.getByRole('button', { name: '客户端下载', exact: true }).click();
      await page.goto(`${origin}/#/about/downloads`, { waitUntil: 'networkidle' });
      if (role === 'admin') {
        await page.getByRole('heading', { name: 'PowerShell 安装证书', exact: true }).waitFor();
        const command = await page.locator('.certificate-command').innerText();
        assert.ok(command.includes('certutil.exe -user -addstore -f Root'));
        assert.ok(command.includes('Get-FileHash'));
        assert.equal(await page.getByRole('link', { name: '下载证书', exact: true }).getAttribute('href'), '/downloads/rustdesk.jtzxsoft.com.cert.cer');
        assert.equal(await page.locator('.certificate-page').getByRole('link', { name: /RustDesk .*Windows x64/ }).count(), 0);
        await page.getByRole('button', { name: '复制命令', exact: true }).click();
        await page.getByRole('button', { name: '已复制', exact: true }).waitFor();
        if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: path.join(process.env.SCREENSHOT_DIR, 'certificate-admin.png'), fullPage: true, animations: 'disabled' });
      } else {
        await page.waitForURL('**/#/403');
        assert.equal(await page.locator('.certificate-command').count(), 0);
        assert.equal(await page.getByRole('link', { name: '下载证书', exact: true }).count(), 0);
      }
      console.log(`下载权限回归通过：${role}，证书页管理员限定`);
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
