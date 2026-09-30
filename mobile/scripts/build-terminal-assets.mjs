import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = path => readFileSync(join(root, path), 'utf8');
const assets = {
  script: read('node_modules/@xterm/xterm/lib/xterm.js'),
  fit: read('node_modules/@xterm/addon-fit/lib/addon-fit.js'),
  css: read('node_modules/@xterm/xterm/css/xterm.css'),
  font: readFileSync(join(root, 'assets/fonts/JetBrainsMono-Regular.ttf')).toString('base64'),
};
writeFileSync(join(root, 'src/terminalAssets.json'), JSON.stringify(assets));
