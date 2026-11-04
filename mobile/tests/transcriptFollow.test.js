const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { TranscriptFollow } = require('../src/transcriptFollow.ts');
const { composerInputHeights } = require('../src/composerLayout.ts');

test('keyboard, composer and streamed output resize the list without ending follow', () => {
  const follow = new TranscriptFollow();
  follow.scroll(420, 500, 1000);
  follow.scroll(420, 230, 1200);
  assert.equal(follow.shouldFollow, true);
  follow.scroll(420, 550, 1400);
  assert.equal(follow.shouldFollow, true);
});

test('scrolling up preserves the reader position through later layout and output', () => {
  const follow = new TranscriptFollow();
  follow.beginGesture(300);
  assert.equal(follow.scroll(300, 400, 1200), false);
  assert.equal(follow.endGesture(300, 400, 1200), false);
  follow.scroll(300, 200, 1600);
  assert.equal(follow.shouldFollow, false);
  follow.jump();
  assert.equal(follow.shouldFollow, true);
});

test('dragging back to the end resumes follow; loading history suspends it', () => {
  const follow = new TranscriptFollow();
  follow.beginGesture(100);
  follow.endGesture(100, 400, 1200);
  follow.beginGesture(100);
  assert.equal(follow.endGesture(760, 400, 1200), true);
  assert.equal(follow.shouldFollow, true);
  follow.stopFollowing();
  assert.equal(follow.shouldFollow, false);
});

test('expanding a file change and scrolling slightly keeps live output from moving the reader', () => {
  const follow = new TranscriptFollow();
  follow.inspect();
  assert.equal(follow.shouldAnchor, false);
  follow.scroll(600, 400, 1000);
  assert.equal(follow.shouldFollow, false);
  follow.beginGesture(600);
  assert.equal(follow.scroll(580, 400, 1000), false);
  assert.equal(follow.endGesture(580, 400, 1000), false);
  follow.scroll(580, 400, 1300);
  assert.equal(follow.shouldFollow, false);
  follow.beginGesture(580);
  assert.equal(follow.endGesture(850, 400, 1300), false);
  follow.beginGesture(850);
  assert.equal(follow.endGesture(900, 400, 1300), true);
  assert.equal(follow.shouldAnchor, true);
});

test('the composer starts at three lines and scrolls within the space a phone has', () => {
  assert.deepEqual(composerInputHeights(844, 0, 47, 1), { minHeight: 78, maxHeight: 180 });
  assert.deepEqual(composerInputHeights(667, 340, 47, 1), { minHeight: 78, maxHeight: 90 });
  assert.deepEqual(composerInputHeights(667, 340, 47, 1.8), { minHeight: 90, maxHeight: 90 });
  assert.deepEqual(composerInputHeights(500, 300, 40, 2), { minHeight: 56, maxHeight: 56 });
});
