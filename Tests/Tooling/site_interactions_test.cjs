// No browser package or network: execute the actual shipped inline script.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '..', '..', 'site', 'index.html'), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1, 'expected exactly one inline site script');
const script = scripts[0][1];
// A test left awaiting a promise that never settles drains the event loop and
// would otherwise exit 0; only a completed run with no failures clears this.
process.exitCode = 1;
let completed = false;
process.on('exit', () => { if (!completed) console.error('FAIL site interaction tests did not complete'); });
function setup({readFails = false, writeFails = false, storageDenied = false, saved = null, clipboard} = {}) {
  function element(attributes = {}) {
    const events = {}, classes = new Set();
    return {events, hidden: true, innerHTML: '', disabled: false, style: {},
      focus() { document.activeElement = this; },
      addEventListener: (event, callback) => { events[event] = callback; },
      getAttribute: key => attributes[key],
      setAttribute: (key, value) => { attributes[key] = value; },
      classList: {add: key => classes.add(key), remove: key => classes.delete(key), contains: key => classes.has(key)}};
  }
  const root = element({'data-lang': 'es', lang: 'es'}), en = element({'data-lang-val': 'en'});
  const hint = element(), brew = element(), lb = element(), image = element(), close = element();
  const thumb = element({'data-full': 'fixture.png'}), thumb2 = element({'data-full': 'second.png'});
  brew.querySelector = () => hint;
  thumb.querySelector = () => element({alt: 'Fixture image'});
  thumb2.querySelector = () => element({alt: 'Second image'});
  // The browser owns modal focus, inertness and Escape; the double models only
  // what the script relies on: autofocus on open and one queued close event.
  Object.assign(lb, {open: false,
    showModal() { this.open = true; close.focus(); },
    close() { if (!this.open) return; this.open = false; return Promise.resolve().then(() => this.events.close()); }});
  const ids = {brew, lightbox: lb, lbImg: image};
  const document = Object.assign(element(), {documentElement: root, body: {style: {}},
    getElementById: key => ids[key], querySelectorAll: selector => selector === '.thumb' ? [thumb, thumb2] : [en]});
  const timers = new Map(); let timerID = 0;
  const storage = {
    getItem: () => { if (readFails) throw Error('blocked read'); return saved; },
    setItem: () => { if (writeFails) throw Error('blocked write'); }};
  const context = {document, navigator: {clipboard},
    setTimeout: callback => { timers.set(++timerID, callback); return timerID; },
    clearTimeout: id => timers.delete(id)};
  // Some browsers throw SecurityError from the localStorage accessor itself.
  Object.defineProperty(context, 'localStorage', {get: () => { if (storageDenied) throw Error('SecurityError'); return storage; }});
  vm.runInNewContext(script, context);
  return {root, en, hint, brew, lb, image, close, thumb, thumb2, document, timers};
}
async function tests() {
  const failures = [];
  async function test(name, work) {
    try { await work(); console.log('PASS ' + name); }
    catch (error) { failures.push(name); console.error('FAIL ' + name + ': ' + error.message); }
  }
  await test('denied storage read does not disable controls', () => {
    const s = setup({readFails: true}); s.en.events.click();
    assert.equal(s.root.getAttribute('lang'), 'en'); s.thumb.events.click(); assert.equal(s.lb.open, true);
  });
  await test('denied storage write preserves current language and controls', () => {
    const s = setup({writeFails: true}); s.en.events.click();
    assert.equal(s.root.getAttribute('lang'), 'en'); s.thumb.events.click(); assert.equal(s.lb.open, true);
  });
  await test('throwing storage accessor does not disable controls', () => {
    const s = setup({storageDenied: true});
    assert.equal(s.root.getAttribute('lang'), 'es'); s.en.events.click();
    assert.equal(s.root.getAttribute('lang'), 'en'); s.thumb.events.click(); assert.equal(s.lb.open, true);
  });
  await test('valid saved language is restored; invalid language ignored', () => {
    assert.equal(setup({saved: 'en'}).root.getAttribute('lang'), 'en');
    assert.equal(setup({saved: 'xx'}).root.getAttribute('lang'), 'es');
  });
  await test('copy stays pending and coalesces repeats until fulfillment', async () => {
    let finish, calls = 0;
    const s = setup({clipboard: {writeText: text => { calls++; assert.equal(text, 'brew install --cask johnny4young/tap/portavoz'); return new Promise(resolve => { finish = resolve; }); }}});
    const pending = s.brew.events.click();
    assert.equal(s.brew.classList.contains('copied'), false);
    assert.equal(s.brew.disabled, false, 'disabling the focused button would drop keyboard focus');
    assert.equal(s.brew.getAttribute('aria-busy'), 'true');
    await s.brew.events.click(); assert.equal(calls, 1);
    finish(); await pending;
    assert.equal(s.brew.classList.contains('copied'), true); assert.equal(s.brew.getAttribute('aria-busy'), 'false');
    assert.match(s.hint.innerHTML, /copiado/); assert.match(s.hint.innerHTML, /copied/);
    for (const callback of s.timers.values()) callback();
    assert.equal(s.brew.classList.contains('copied'), false);
  });
  await test('rejected clipboard reports failure and allows retry', async () => {
    let fails = true;
    const s = setup({clipboard: {writeText: () => fails ? Promise.reject(Error('permission denied')) : Promise.resolve()}});
    await s.brew.events.click(); assert.equal(s.brew.classList.contains('copied'), false);
    assert.match(s.hint.innerHTML, /manually/); assert.match(s.hint.innerHTML, /manualmente/);
    assert.equal(s.brew.getAttribute('aria-busy'), 'false'); fails = false; await s.brew.events.click();
    assert.equal(s.brew.classList.contains('copied'), true);
  });
  await test('unavailable clipboard never announces success', async () => {
    const s = setup(); await s.brew.events.click();
    assert.equal(s.brew.classList.contains('copied'), false); assert.match(s.hint.innerHTML, /manually/);
  });
  await test('synchronous clipboard failure is recoverable', async () => {
    const s = setup({clipboard: {writeText: () => { throw Error('blocked'); }}});
    await s.brew.events.click(); assert.equal(s.brew.getAttribute('aria-busy'), 'false'); assert.match(s.hint.innerHTML, /manually/);
  });
  await test('lightbox is a native modal dialog that autofocuses its close control', () => {
    assert.match(html, /<dialog\b[^>]*\bid="lightbox"/);
    assert.match(html, /<button\b[^>]*\bclass="lb-close"[^>]*\bautofocus\b/);
    const s = setup(); s.thumb.focus(); s.thumb.events.click();
    assert.equal(s.lb.open, true); assert.equal(s.image.getAttribute('src'), 'fixture.png');
    assert.equal(s.image.getAttribute('alt'), 'Fixture image');
    assert.equal(s.document.activeElement, s.close);
  });
  await test('lightbox image stays open; every close route restores the launcher', async () => {
    const s = setup();
    // Escape reaches the script only as the dialog's close event.
    for (const close of [() => s.lb.events.click({target: s.lb}), () => s.lb.events.click({target: s.close}), () => s.lb.close()]) {
      s.en.focus(); s.thumb.events.click();
      s.lb.events.click({target: s.image});
      assert.equal(s.lb.open, true); assert.equal(s.document.activeElement, s.close);
      close(); await new Promise(setImmediate);
      assert.equal(s.lb.open, false); assert.equal(s.image.getAttribute('src'), '');
      assert.equal(s.document.activeElement, s.thumb, 'restore the launcher even if a pointer click did not focus it');
    }
  });
  await test('lightbox reopen restores the latest exact launcher', async () => {
    const s = setup(); s.thumb.events.click(); await s.lb.close();
    s.thumb2.events.click();
    assert.equal(s.document.activeElement, s.close); assert.equal(s.image.getAttribute('src'), 'second.png');
    await s.lb.close(); assert.equal(s.document.activeElement, s.thumb2);
  });
  completed = true;
  process.exitCode = failures.length ? 1 : 0;
}
tests();
