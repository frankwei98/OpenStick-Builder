'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const webRoot = path.resolve(__dirname, '..', 'src', 'openstick-setup', 'web');
const files = new Map([
    ['/', ['index.html', 'text/html; charset=utf-8']],
    ['/style.css', ['style.css', 'text/css; charset=utf-8']],
    ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
]);

async function startStaticServer() {
    const server = http.createServer(async (request, response) => {
        const entry = files.get(new URL(request.url, 'http://local.test').pathname);
        if (!entry) {
            response.writeHead(404).end('not found');
            return;
        }
        try {
            const data = await fs.readFile(path.join(webRoot, entry[0]));
            response.writeHead(200, { 'Content-Type': entry[1], 'Cache-Control': 'no-store' });
            response.end(data);
        } catch (error) {
            response.writeHead(500).end(String(error));
        }
    });
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(0, '127.0.0.1', resolve);
    });
    return { server, url: `http://127.0.0.1:${server.address().port}/` };
}

async function newSetupPage(browser, baseURL, options = {}) {
    const context = await browser.newContext({ viewport: options.viewport || { width: 1024, height: 768 } });
    const page = await context.newPage();
    let setupCalls = 0;

    await page.route('**/api/session', async route => {
        if (options.session === 'abort') {
            await route.abort('connectionfailed');
            return;
        }
        const status = options.sessionStatus || 200;
        await route.fulfill({
            status,
            contentType: 'application/json',
            body: status === 200
                ? JSON.stringify({ token: 'a'.repeat(64), address: '127.0.0.1', username: 'openstick' })
                : JSON.stringify({ status: status === 409 ? 'configured' : 'unavailable' }),
        });
    });
    await page.route('**/api/setup', async route => {
        setupCalls++;
        if (options.setup === 'abort') {
            await route.abort('connectionfailed');
            return;
        }
        const status = options.setupStatus || 200;
        await route.fulfill({
            status,
            contentType: 'application/json',
            body: JSON.stringify({ status: status === 200 || status === 409 ? 'configured' : 'unavailable' }),
        });
    });
    await page.goto(baseURL);
    return { context, page, setupCalls: () => setupCalls };
}

async function waitUntilConnected(page) {
    await page.waitForFunction(() => {
        const button = document.getElementById('submit');
        return button && !button.disabled && button.textContent === '设置管理员密码';
    });
}

async function submitPassword(page, password, confirmation = password) {
    await page.locator('#password').fill(password);
    await page.locator('#confirmation').fill(confirmation);
    await page.locator('#setup-form').evaluate(form => form.requestSubmit());
}

async function testSessionFailure(browser, baseURL) {
    const { context, page } = await newSetupPage(browser, baseURL, { session: 'abort' });
    try {
        await page.locator('#error:not([hidden])').waitFor();
        assert.match(await page.locator('#error').textContent(), /暂时无法连接设置服务/);
        assert.equal(await page.locator('#submit').isDisabled(), true);
        assert.equal(await page.locator('#submit').textContent(), '暂时无法设置');
        assert.equal(await page.locator('#success-view').isHidden(), true);
    } finally {
        await context.close();
    }
}

async function testLocalValidationAndReveal(browser, baseURL) {
    const state = await newSetupPage(browser, baseURL);
    const { context, page } = state;
    try {
        await waitUntilConnected(page);
        await submitPassword(page, 'too short');
        await page.locator('#error:not([hidden])').waitFor();
        assert.match(await page.locator('#error').textContent(), /12–128/);
        assert.equal(state.setupCalls(), 0);

        await submitPassword(page, 'correct horse battery staple', 'correct horse battery staplf');
        assert.match(await page.locator('#error').textContent(), /两次输入的密码不一致/);
        assert.equal(state.setupCalls(), 0);

        await page.locator('#reveal').click();
        assert.equal(await page.locator('#password').getAttribute('type'), 'text');
        assert.equal(await page.locator('#confirmation').getAttribute('type'), 'text');
        assert.equal(await page.locator('#reveal').getAttribute('aria-pressed'), 'true');
        await page.locator('#reveal').click();
        assert.equal(await page.locator('#password').getAttribute('type'), 'password');
        assert.equal(await page.locator('#confirmation').getAttribute('type'), 'password');
        assert.equal(await page.locator('#reveal').getAttribute('aria-pressed'), 'false');
    } finally {
        await context.close();
    }
}

async function testSuccessfulSetup(browser, baseURL) {
    const state = await newSetupPage(browser, baseURL);
    const { context, page } = state;
    try {
        await waitUntilConnected(page);
        await submitPassword(page, 'correct horse battery staple');
        await page.locator('#success-view:not([hidden])').waitFor();
        assert.equal(state.setupCalls(), 1);
        assert.equal(await page.locator('#setup-view').isHidden(), true);
        assert.equal(await page.locator('#success-title').textContent(), '设备准备好了。');
        assert.equal(await page.locator('#ssh-command').textContent(), 'ssh openstick@127.0.0.1');
        assert.equal(await page.title(), 'OpenStick · 设置完成');
    } finally {
        await context.close();
    }
}

async function testConcurrentConfigurationWins(browser, baseURL) {
    const state = await newSetupPage(browser, baseURL, { setupStatus: 409 });
    const { context, page } = state;
    try {
        await waitUntilConnected(page);
        await submitPassword(page, 'correct horse battery staple');
        await page.locator('#success-view:not([hidden])').waitFor();
        assert.equal(state.setupCalls(), 1);
        assert.equal(await page.locator('#success-title').textContent(), '设备已完成设置。');
        assert.match(await page.locator('#success-description').textContent(), /本次提交没有修改密码/);
    } finally {
        await context.close();
    }
}

async function testUncertainFailuresNeverReportSuccess(browser, baseURL) {
    for (const options of [{ setupStatus: 503 }, { setup: 'abort' }]) {
        const state = await newSetupPage(browser, baseURL, options);
        const { context, page } = state;
        try {
            await waitUntilConnected(page);
            await submitPassword(page, 'correct horse battery staple');
            await page.locator('#error:not([hidden])').waitFor();
            assert.equal(state.setupCalls(), 1);
            assert.equal(await page.locator('#success-view').isHidden(), true);
            assert.match(await page.locator('#error').textContent(), /未能确认设置结果|连接中断，尚未确认设置结果/);
            assert.equal(await page.locator('#submit').isDisabled(), true);
        } finally {
            await context.close();
        }
    }
}

async function testNarrowViewportDoesNotOverflow(browser, baseURL) {
    const state = await newSetupPage(browser, baseURL, { viewport: { width: 320, height: 720 } });
    const { context, page } = state;
    try {
        await waitUntilConnected(page);
        const dimensions = await page.evaluate(() => ({
            viewport: document.documentElement.clientWidth,
            page: document.documentElement.scrollWidth,
            body: document.body.scrollWidth,
        }));
        assert.ok(dimensions.page <= dimensions.viewport, JSON.stringify(dimensions));
        assert.ok(dimensions.body <= dimensions.viewport, JSON.stringify(dimensions));
    } finally {
        await context.close();
    }
}

async function main() {
    const { server, url } = await startStaticServer();
    let browser;
    try {
        browser = await chromium.launch({ headless: true });
        await testSessionFailure(browser, url);
        await testLocalValidationAndReveal(browser, url);
        await testSuccessfulSetup(browser, url);
        await testConcurrentConfigurationWins(browser, url);
        await testUncertainFailuresNeverReportSuccess(browser, url);
        await testNarrowViewportDoesNotOverflow(browser, url);
        process.stdout.write('OpenStick setup UI tests passed\n');
    } finally {
        if (browser) {
            await browser.close();
        }
        await new Promise(resolve => server.close(resolve));
    }
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
