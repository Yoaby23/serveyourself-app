import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const root = new URL('..', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
function listeners() {
    const events = new Map();
    const document = {
        readyState: 'loading', querySelector: () => ({}),
        addEventListener(type, callback, options) { events.set(type, {callback, options}); }
    };
    const window = {supabase: {createClient: () => ({})}, addEventListener() {}};
    vm.runInNewContext(read('app.js'), {window, document, navigator: {}, location: {}});
    return events;
}
function dispatch(events, type, data = {}) {
    let prevented = false;
    events.get(type).callback({cancelable: true, preventDefault() {prevented = true;}, ...data});
    return prevented;
}
test('all screens request a device-sized stable viewport', () => {
    for (const page of fs.readdirSync(root).filter(name => name.endsWith('.html'))) {
        const viewport = read(page).match(/<meta name="viewport" content="([^"]+)"/)[1];
        for (const directive of ['width=device-width', 'initial-scale=1', 'minimum-scale=1', 'maximum-scale=1', 'user-scalable=no', 'viewport-fit=cover']) assert.ok(viewport.includes(directive), `${page}: ${directive}`);
    }
});
test('page zoom gestures are canceled while normal scrolling and map gestures remain available', () => {
    const events = listeners();
    for (const type of ['gesturestart', 'gesturechange', 'touchmove', 'wheel']) assert.equal(events.get(type).options.passive, false);
    assert.equal(dispatch(events, 'gesturestart'), true);
    assert.equal(dispatch(events, 'wheel', {ctrlKey: true}), true);
    assert.equal(dispatch(events, 'wheel'), false);
    assert.equal(dispatch(events, 'touchmove', {touches: [1]}), false);
    assert.equal(dispatch(events, 'touchmove', {touches: [1, 2]}), true);
    assert.equal(dispatch(events, 'touchmove', {touches: [1, 2], target: {closest: () => ({})}}), false);
    assert.equal(dispatch(events, 'gesturechange', {cancelable: false}), false);
});
test('zoom shortcuts are canceled without intercepting typing or common shortcuts', () => {
    const events = listeners();
    for (const key of ['+', '-', '=', '0']) {
        assert.equal(dispatch(events, 'keydown', {key, ctrlKey: true}), true);
        assert.equal(dispatch(events, 'keydown', {key, metaKey: true}), true);
        assert.equal(dispatch(events, 'keydown', {key}), false);
    }
    for (const key of ['c', 'v', 'Tab', 'ArrowRight']) assert.equal(dispatch(events, 'keydown', {key, ctrlKey: true}), false);
});
