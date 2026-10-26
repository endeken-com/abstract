const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, path);
};
const { sendPhoneDraft, visiblePhoneMessages } = require('../src/chatSending.ts');
const line = (seq, text) => ({ seq, line: { stream: 'user', line: text } });
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

test('a delayed Mac gets one request and the pending draft appears immediately', async () => {
  const mac = deferred();
  const lock = { current: false };
  const pending = [];
  let requests = 0;
  let composer = 'Hello';
  const draft = { text: composer, attachments: [] };
  const send = () => sendPhoneDraft(lock, draft, () => { requests++; return mac.promise; },
    () => { pending.push({ ...draft, id: 'first', afterSeq: 4, status: 'sending' }); composer = ''; },
    () => { pending[0].status = 'accepted'; },
    () => { composer = draft.text; pending.length = 0; });
  const first = send();
  const second = send();
  assert.equal(composer, '');
  assert.equal(pending[0].status, 'sending');
  assert.equal(lock.current, true);
  await Promise.resolve();
  assert.equal(requests, 1);
  mac.resolve({ ok: {} });
  assert.equal(await first, true);
  assert.equal(await second, false);
  assert.equal(pending[0].status, 'accepted');
  assert.equal(visiblePhoneMessages(pending, [line(5, 'Hello')]).length, 0);

  const next = deferred();
  const followUp = { text: 'Another message', attachments: [] };
  const third = sendPhoneDraft(lock, followUp, () => next.promise, () => {}, () => {}, () => {});
  assert.equal(lock.current, true);
  next.resolve({ ok: {} });
  assert.equal(await third, true);
});

test('rejection, timeout, and disconnect return the exact draft and attachments', async () => {
  for (const reason of ['Rejected', 'Mac did not respond.', 'Mac disconnected.']) {
    const mac = deferred();
    const lock = { current: false };
    const attachment = { id: 'file-1', kind: 'file', title: 'notes.txt', reference: null, data: 'dGVzdA==' };
    const draft = { text: '  Keep my spacing  ', attachments: [attachment] };
    let composer = draft;
    let pending = false;
    let error;
    const result = sendPhoneDraft(lock, draft, () => mac.promise,
      () => { composer = { text: '', attachments: [] }; pending = true; },
      () => { pending = false; },
      failure => { composer = draft; pending = false; error = failure.message; });
    assert.equal(pending, true);
    mac.reject(Error(reason));
    assert.equal(await result, false);
    assert.equal(error, reason);
    assert.equal(lock.current, false);
    assert.deepEqual(composer, draft);
    assert.strictEqual(composer.attachments[0], attachment);
  }
});

test('each transcript line reconciles only one identical sent draft', () => {
  const draft = { text: 'Same', attachments: [] };
  const pending = [
    { ...draft, id: 'one', afterSeq: 3, status: 'accepted' },
    { ...draft, id: 'two', afterSeq: 3, status: 'accepted' },
  ];
  assert.deepEqual(visiblePhoneMessages(pending, [line(2, 'Same'), line(4, 'Same')]).map(x => x.id), ['two']);
  assert.equal(visiblePhoneMessages(pending, [line(2, 'Same'), line(4, 'Same'), line(5, 'Same')]).length, 0);
});

test('attachment messages reconcile using the Mac transcript tags', () => {
  const pending = [{ id: 'attachment', afterSeq: 0, status: 'accepted', text: 'See this', attachments: [
    { id: 'issue', kind: 'githubIssue', reference: '#12', title: 'A & B' },
  ] }];
  const recorded = 'See this\n\n<attachment kind="githubIssue" label="#12 A &amp; B" target="https://example.test">\nGitHub Issue #12: A & B\n</attachment>';
  assert.equal(visiblePhoneMessages(pending, [line(1, recorded)]).length, 0);
  assert.equal(visiblePhoneMessages(pending, [line(1, 'See this')]).length, 1);
});

test('a message queued mid-turn clears once the Mac logs it joined with others', () => {
  const pending = [
    { id: 'a', text: 'first', attachments: [], afterSeq: 4, status: 'accepted' },
    { id: 'b', text: 'second', attachments: [], afterSeq: 4, status: 'accepted' },
    { id: 'c', text: 'third', attachments: [], afterSeq: 4, status: 'accepted' },
  ];
  assert.deepEqual(visiblePhoneMessages(pending, [line(5, 'first\n\nsecond\n\nthird')]), []);
  // Only whole parts count, not words inside them.
  assert.deepEqual(visiblePhoneMessages([{ ...pending[0], text: 'irs' }], [line(5, 'first\n\nsecond')]).map(x => x.id), ['a']);
});
