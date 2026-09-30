const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');
require.extensions['.ts'] = (module, path) => module._compile(ts.transpileModule(fs.readFileSync(path, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true }
}).outputText, path);
const { parseInvitation } = require('../src/internet.ts');
const invite = () => ({ v: 1, peer: { id: 'host', name: 'Mac', publicKey: Buffer.alloc(32, 1).toString('base64') },
  address: { endpointId: 'a'.repeat(64) }, token: Buffer.alloc(32, 2).toString('base64'), expires: Math.floor(Date.now() / 1000) + 600 });
const link = value => 'abstract://connect/' + Buffer.from(JSON.stringify(value)).toString('base64url');
test('invitation pins the host and rejects expired, malformed and arbitrary relay addresses', () => {
  const valid = invite();
  assert.deepEqual(parseInvitation(link(valid)), valid);
  assert.throws(() => parseInvitation(link({ ...valid, expires: 1 })));
  assert.throws(() => parseInvitation(link({ ...valid, address: { endpointId: 'https://attacker.example' } })));
  assert.throws(() => parseInvitation(link({ ...valid, token: 'short' })));
  assert.throws(() => parseInvitation('https://example.com/' + link(valid)));
  assert.throws(() => parseInvitation('abstract://connect/' + 'a'.repeat(5000)));
});
