const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const js = ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { FrameDecoder } = require('../src/framing.ts');
const frame = body => { const header = Buffer.alloc(4); header.writeUInt32BE(body.length); return Buffer.concat([header, body]); };

test('frames survive split headers, split bodies, and adjacent messages', () => {
  const decoder = new FrameDecoder();
  const large = Buffer.alloc(2 << 20, 0x61);
  const wire = Buffer.concat([frame(Buffer.from('one')), frame(large), frame(Buffer.from('three'))]);
  const output = [];
  for (let offset = 0; offset < wire.length; offset += 4093) output.push(...decoder.push(wire.subarray(offset, offset + 4093)));
  assert.deepEqual(output.map(part => part.length), [3, large.length, 5]);
  assert.equal(output[0].toString(), 'one');
  assert.equal(output[1].compare(large), 0);
  assert.equal(output[2].toString(), 'three');
});

test('oversized frames are rejected before allocation', () => {
  const decoder = new FrameDecoder();
  const header = Buffer.alloc(4);
  header.writeUInt32BE((16 << 20) + 1);
  assert.throws(() => decoder.push(header), /too large/);
});
