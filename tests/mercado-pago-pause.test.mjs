import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';

const source = readFileSync(new URL('../supabase/functions/mercado-pago-disconnect/index.ts', import.meta.url), 'utf8')
    .replace(/^import .*;\n/gm, '');

function setup(restaurant, user = { id: 'merchant' }) {
    const changes = [];
    let handler;
    const query = {
        update(values) { changes.push(['update', ...Object.entries(values)]); return this; },
        eq(column, value) { changes.push(['filter', column, value]); return this; },
        select() { return this; },
        maybeSingle: async () => ({ data: restaurant })
    };

    vm.runInNewContext(stripTypeScriptTypes(source), {
        Deno: { env: { get: name => name }, serve: fn => { handler = fn; } },
        createClient: (_url, key) => key === 'SUPABASE_ANON_KEY'
            ? { auth: { getUser: async () => ({ data: { user } }) } }
            : { from: table => { assert.equal(table, 'profiles'); return query; } },
        jsonResponse: (_request, body, status = 200) => Response.json(body, { status })
    });

    return {
        changes,
        pause: () => handler(new Request('https://edge.test', { method: 'POST', headers: { authorization: 'Bearer test' } }))
    };
}

test('pausing online checkout preserves the connected merchant and does not delete payment credentials', async () => {
    const { changes, pause } = setup({ id: 'merchant' });
    const response = await pause();
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { paused: true });
    assert.deepEqual(changes, [
        ['update', ['payment_online', false]],
        ['filter', 'id', 'merchant'],
        ['filter', 'role', 'negocio']
    ]);
});

test('pausing checkout requires an authenticated restaurant', async () => {
    assert.equal((await setup(null).pause()).status, 403);
    const noSession = setup(null, null);
    assert.equal((await noSession.pause()).status, 401);
    assert.deepEqual(noSession.changes, []);
});
