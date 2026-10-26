const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const ts = require('typescript');

const transpile = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  const js = ts.transpileModule(source, { fileName: path, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.React, esModuleInterop: true } }).outputText;
  module._compile(js, path);
};
require.extensions['.ts'] = transpile;
require.extensions['.tsx'] = transpile;
// The native modules are stood in by their element names, so the pill renders to a plain element tree.
const stubs = {
  'react-native': { Pressable: 'Pressable', Text: 'Text', View: 'View', StyleSheet: { create: styles => styles, hairlineWidth: 0.5 } },
  'expo-symbols': { SymbolView: 'SymbolView' },
  'react-native-svg': { __esModule: true, default: 'Svg', Path: 'Path' },
};
const load = Module._load;
Module._load = function (request, ...rest) { return stubs[request] || load.call(this, request, ...rest); };
const { chatContext } = require('../src/chatContext.ts');
const { ContextPill, contextPillStyles } = require('../src/ContextPill.tsx');
const { BranchIcon } = require('../src/PullRequestIcon.tsx');

const chat = (fields = {}) => ({ branch: null, worktreePath: null, projectId: null, ...fields });

test('a chat with a branch shows the branch, captioned BRANCH, with the branch icon', () => {
  assert.deepEqual(chatContext(chat({ branch: 'fix/pill-width', worktreePath: '/tmp/worktrees/abuja', projectId: 'p1' }), 'Abstract'),
    { caption: 'BRANCH', label: 'fix/pill-width', icon: 'branch', accessibilityLabel: 'Branch fix/pill-width' });
});

test('a worktree without a branch shows the worktree folder with the worktree icon', () => {
  assert.deepEqual(chatContext(chat({ worktreePath: '/tmp/worktrees/abuja/', projectId: 'p1' }), 'Abstract'),
    { caption: 'WORKTREE', label: 'abuja', icon: 'worktree', accessibilityLabel: 'Worktree abuja' });
});

test('a project chat without a worktree shows the project', () => {
  assert.deepEqual(chatContext(chat({ projectId: 'p1' }), 'Abstract'),
    { caption: 'PROJECT', label: 'Abstract', icon: 'project', accessibilityLabel: 'Project Abstract' });
});

test('a standalone chat says so', () => {
  assert.deepEqual(chatContext(chat()), { caption: 'STANDALONE', label: 'No project', icon: 'standalone', accessibilityLabel: 'Standalone chat' });
});

test('the pill draws the git-branch Octicon for a branch and the worktree symbol for a worktree', () => {
  const branch = ContextPill({ context: chatContext(chat({ branch: 'main' })) });
  assert.equal(branch.props.accessibilityLabel, 'Branch main');
  assert.equal(branch.props.children[0].type, BranchIcon);
  const worktree = ContextPill({ context: chatContext(chat({ worktreePath: '/tmp/worktrees/abuja' })) });
  assert.equal(worktree.props.children[0].type, 'SymbolView');
  assert.equal(worktree.props.children[0].props.name.ios, 'arrow.triangle.branch');
  const [caption, name] = branch.props.children[1].props.children;
  assert.equal(caption.props.children, 'BRANCH');
  assert.equal(name.props.children, 'main');
  assert.equal(name.props.numberOfLines, 1);
  assert.equal(name.props.ellipsizeMode, 'middle');
});

test('the PR and changes pills beside it never shrink', () => {
  const source = fs.readFileSync(require.resolve('../src/ChatWorkspace.tsx'), 'utf8');
  for (const style of ['prContext', 'changesPill']) assert.match(source, new RegExp(`\\b${style}: \\{ flexShrink: 0,`));
});

// Lays out the row above the reply box with Yoga, React Native's layout engine, on a 375-point-wide phone.
async function layOut(branchName) {
  const { loadYoga } = await import('yoga-layout/load');
  const Yoga = await loadYoga();
  const node = (style, children = []) => {
    const n = Yoga.Node.create();
    if (style.flexDirection === 'row') n.setFlexDirection(Yoga.FLEX_DIRECTION_ROW);
    if (style.alignItems === 'center') n.setAlignItems(Yoga.ALIGN_CENTER);
    if (style.flex != null) n.setFlex(style.flex);
    if (style.flexGrow != null) n.setFlexGrow(style.flexGrow);
    n.setFlexShrink(style.flexShrink ?? 0);
    if (style.minWidth != null) n.setMinWidth(style.minWidth);
    if (style.width != null) n.setWidth(style.width);
    if (style.height != null) n.setHeight(style.height);
    if (style.gap != null) n.setGap(Yoga.GUTTER_ALL, style.gap);
    if (style.paddingHorizontal != null) n.setPadding(Yoga.EDGE_HORIZONTAL, style.paddingHorizontal);
    if (style.borderWidth != null) n.setBorder(Yoga.EDGE_ALL, style.borderWidth);
    children.forEach((child, index) => n.insertChild(child, index));
    return n;
  };
  // A one-line text is as wide as its characters (7 points each), cut to the room it's given.
  const text = characters => {
    const n = Yoga.Node.create();
    n.setMeasureFunc((width, mode) => ({ width: mode === Yoga.MEASURE_MODE_UNDEFINED ? characters * 7 : Math.min(characters * 7, width), height: 15 }));
    return n;
  };
  const { pill, text: column } = contextPillStyles;
  const pillNode = node(pill, [node({ width: 15, height: 15 }), node(column, [text('BRANCH'.length), text(branchName.length)])]);
  const pr = node({ width: 52, height: 32 }), changes = node({ width: 104, height: 32 });
  const row = node({ flexDirection: 'row', alignItems: 'center', gap: 6, width: 355, height: 40 }, [pillNode, pr, changes]);
  row.calculateLayout(355, 40, Yoga.DIRECTION_LTR);
  const result = { pill: pillNode.getComputedLayout(), pr: pr.getComputedLayout(), changes: changes.getComputedLayout(), content: 2 * 8 + 2 * 0.5 + 15 + 7 + Math.max('BRANCH'.length, branchName.length) * 7 };
  row.freeRecursive();
  return result;
}

test('a short branch name gives a short pill, with the PR and changes pills right beside it', async () => {
  const { pill, pr, changes, content } = await layOut('main');
  assert.ok(Math.abs(pill.width - content) < 1, `pill is ${pill.width} wide for ${content} of content`);
  assert.equal(pr.left, pill.width + 6);
  assert.equal(changes.left, pr.left + 52 + 6);
});

test('a long branch name is cut without pushing the other pills off-screen', async () => {
  const { pill, pr, changes } = await layOut('auto/roadmap-build-the-next-ticket/2026-10-13-1753');
  assert.equal(pr.width, 52);
  assert.equal(changes.width, 104);
  assert.equal(changes.left + changes.width, 355);
  assert.equal(pill.width, 355 - 52 - 104 - 12);
});
