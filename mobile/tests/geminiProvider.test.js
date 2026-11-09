const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  module._compile(js, path);
};
const { toolKind, toolTarget, toolVerb, toolSymbol } = require('../src/toolPresentation.ts');
const logos = require('../src/providerLogos.json');

test('Gemini is pictured and its CLI tools read on the phone', () => {
  assert.match(logos.gemini, /<svg/);
  assert.equal(toolKind('run_command'), 'command');
  assert.equal(toolVerb('run_command', true), 'Running');
  assert.equal(toolSymbol('run_command'), 'terminal');
  assert.deepEqual(toolTarget('run_command', { command: 'pwd' }), { text: 'pwd' });
  assert.equal(toolKind('write_to_file'), 'edit');
  assert.equal(toolVerb('write_to_file'), 'Created');
  assert.deepEqual(toolTarget('read_file', { file_path: '/workspace/README.txt' }),
    { text: 'README.txt', path: '/workspace/README.txt' });
});
