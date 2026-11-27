import assert from 'node:assert/strict';
import { test } from 'node:test';
import auth from '../desktop/auth.cjs';

const { SITE, BACKEND, createAuthReceiver } = auth;

test('desktop OAuth returns a one-time result to its original page', async t => {
    let finished;
    const receiver = createAuthReceiver(url => { finished = new URL(url); });
    t.after(() => receiver.close());
    await assert.rejects(receiver.begin('https://example.com/index.html'));
    await assert.rejects(receiver.begin(`${SITE}/caja.html`));
    const first = await receiver.begin(`${SITE}/index.html?oauth=1`);
    const callback = await receiver.begin(`${SITE}/registro.html?role=restaurant&oauth=1&next=caja.html`);
    assert.notEqual(first, callback);
    const authorize = new URL('/auth/v1/authorize', BACKEND);
    authorize.search = new URLSearchParams({
        provider: 'google', redirect_to: callback, code_challenge_method: 's256', code_challenge: 'A'.repeat(43)
    });
    assert.ok(receiver.authorize(authorize.href));
    assert.equal(receiver.authorize(authorize.href.replace('provider=google', 'provider=github')), false);
    assert.equal((await fetch(`${first}?code=wrong`)).status, 404);
    const response = await fetch(`${callback}?code=test-code&next=https://example.com`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.match(await response.text(), /Continúa en ServeYourself/);
    assert.equal(finished.href, `${SITE}/registro.html?role=restaurant&oauth=1&next=caja.html&code=test-code`);
    assert.equal((await fetch(`${callback}?code=second`)).status, 404);
});
