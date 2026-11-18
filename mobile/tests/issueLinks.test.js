const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');

require.extensions['.ts'] = (module, path) => {
  const source = fs.readFileSync(path, 'utf8');
  module._compile(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, path);
};
const links = require('../src/issueLinks.ts');
const { visiblePhoneMessages } = require('../src/chatSending.ts');

// ABS-211: the phone's composers link Linear and Jira issues through the
// Mac. Every key, title and link here is made up.
const jira = { id: 'sh.abstract.jira', title: 'Jira', keyExample: 'SHOP-1', version: '1.1.0', link: 'Shop', linkKey: 'SHOP', icon: Buffer.from('<svg/>').toString('base64'), iconFormat: 'svg', iconIsTemplate: false };
const linear = { id: 'sh.abstract.linear', title: 'Linear', keyExample: 'ENG-1', version: '1.2.0', link: 'ENG · Core', linkKey: 'ENG' };
const unlinked = tracker => ({ ...tracker, link: null, linkKey: null });
const menu = (sources, extra = {}) => links.linkMenuActions({ supported: true, online: true, macName: 'Studio', sources, hasRepository: true, platform: 'ios', ...extra });
const titles = actions => actions.map(action => action.title);

test('a Jira project offers its Jira issues and its code host’s pull requests, not GitHub issues', () => {
  const actions = menu({ trackers: [jira], linked: true, codeHost: 'Bitbucket', githubIssues: false, pullRequests: true });
  assert.deepEqual(titles(actions), ['Link a Jira issue', 'Link a pull request']);
  assert.equal(actions[0].id, 'link:tracker:sh.abstract.jira');
  assert.equal(actions[0].subtitle, 'Shop');
  assert.equal(actions[1].subtitle, 'Bitbucket');
  assert.ok(actions.every(action => !action.attributes?.disabled));
});

test('a Linear project on GitHub offers Linear and GitHub issues and pull requests', () => {
  const actions = menu({ trackers: [linear], linked: true, codeHost: 'GitHub', githubIssues: true, pullRequests: true });
  assert.deepEqual(titles(actions), ['Link a Linear issue', 'Link a GitHub issue', 'Link a pull request']);
});

test('a project linked to both trackers names each', () => {
  assert.deepEqual(titles(menu({ trackers: [jira, linear], linked: true, githubIssues: false, pullRequests: true })), ['Link a Jira issue', 'Link a Linear issue', 'Link a pull request']);
});

test('a project with no linked tracker searches every tracker that’s on in one item', () => {
  const actions = menu({ trackers: [unlinked(jira), unlinked(linear)], linked: false, githubIssues: true, pullRequests: true });
  assert.deepEqual(titles(actions), ['Link an issue', 'Link a GitHub issue', 'Link a pull request']);
  assert.equal(actions[0].id, 'link:tracker:');
  assert.equal(actions[0].subtitle, 'Jira or Linear');
  // With only one on, it's named.
  assert.deepEqual(titles(menu({ trackers: [unlinked(linear)], linked: false, githubIssues: false, pullRequests: false })), ['Link a Linear issue']);
});

test('a GitHub-only project keeps GitHub issues and pull requests', () => {
  assert.deepEqual(titles(menu({ trackers: [], linked: false, codeHost: 'GitHub', githubIssues: true, pullRequests: true })), ['Link a GitHub issue', 'Link a pull request']);
});

test('with the Mac unreachable every item is disabled and says so', () => {
  const sources = { trackers: [jira], linked: true, codeHost: 'Bitbucket', githubIssues: false, pullRequests: true };
  const actions = menu(sources, { online: false });
  assert.deepEqual(titles(actions), ['Link a Jira issue', 'Link a pull request']);
  assert.ok(actions.every(action => action.attributes?.disabled && action.subtitle === "Studio isn't reachable"));
  // Never reached yet: one item, disabled, saying the same.
  const unknown = menu(null, { online: false });
  assert.deepEqual(unknown.map(action => [action.title, action.subtitle, action.attributes?.disabled]), [['Link an issue', "Studio isn't reachable", true]]);
});

test('while the Mac is asked, or if asking failed, the item waits disabled with a sentence', () => {
  assert.equal(menu(null)[0].subtitle, 'Asking Studio…');
  const failed = menu(null, { error: 'Mac did not respond.' });
  assert.deepEqual([failed[0].subtitle, failed[0].attributes?.disabled], ['Mac did not respond.', true]);
});

test('an older Mac keeps GitHub through gh and says trackers need an update there', () => {
  const actions = menu(null, { supported: false });
  assert.deepEqual(titles(actions), ['Link a Linear or Jira issue', 'Link a GitHub issue', 'Link a pull request']);
  assert.equal(actions[0].attributes?.disabled, true);
  assert.equal(actions[0].subtitle, 'Update Abstract on Studio to link Linear or Jira issues');
  assert.ok(!actions[1].attributes?.disabled);
  assert.deepEqual(links.legacyGitHubArgs({ kind: 'pullRequest' }, ''), ['pr', 'list', '--limit', '30', '--json', 'number,title,url,state,body,isDraft,baseRefName,headRefName', '--state', 'open']);
  const group = links.legacyGitHubGroup({ kind: 'githubIssue' }, [{ number: 4, title: 'Crash', url: 'https://github.com/example/app/issues/4', state: 'OPEN' }]);
  assert.deepEqual([group.results[0].reference, group.results[0].state, group.results[0].attachment.kind], ['#4', 'Open', 'githubIssue']);
});

test('menu events open the right sheet', () => {
  assert.deepEqual(links.linkSourceOf('link:tracker:sh.abstract.jira'), { kind: 'tracker', trackerId: 'sh.abstract.jira' });
  assert.deepEqual(links.linkSourceOf('link:tracker:'), { kind: 'tracker', trackerId: null });
  assert.deepEqual(links.linkSourceOf('link:pullRequest'), { kind: 'pullRequest' });
  assert.equal(links.linkSourceOf('attach'), null);
});

test('the search sheet names its tracker and asks the Mac for what was typed, a key whole', () => {
  const sources = { trackers: [jira, linear], linked: true, githubIssues: false, pullRequests: true };
  const source = { kind: 'tracker', trackerId: 'sh.abstract.jira' };
  assert.equal(links.sheetTitle(sources, source), 'Find a Jira issue');
  assert.equal(links.searchPlaceholder(sources, source), 'Search Jira issues, or paste SHOP-1');
  assert.equal(links.searchPlaceholder(sources, { kind: 'tracker', trackerId: null }), 'Search Jira and Linear, or paste a key or link');
  assert.deepEqual(links.searchRequest(source, ' SHOP-42 ', { projectId: 'p1', chatId: 'c1' }),
    { name: 'searchIssues', args: { projectId: 'p1', chatId: 'c1', trackerId: 'sh.abstract.jira', query: 'SHOP-42', searchAll: false } });
  assert.deepEqual(links.searchRequest({ kind: 'pullRequest' }, 'retry', { projectId: 'p1', chatId: null }),
    { name: 'searchCodeHost', args: { projectId: 'p1', chatId: null, query: 'retry', pullRequests: true } });
  assert.equal(links.namesGroups(source, [{}]), true);
  assert.equal(links.namesGroups({ kind: 'pullRequest' }, [{}]), false);
});

test('a picked tracker issue is kept as a trackerIssue attachment naming its tracker', () => {
  const picked = links.pickedFromMac({ id: 'a1', kind: 'trackerIssue', title: 'Checkout retries twice', reference: 'SHOP-42', url: 'https://example.atlassian.net/browse/SHOP-42', body: 'Twice.', details: ['State: In Progress'], tracker: 'sh.abstract.jira', trackerName: 'Jira' });
  assert.equal(picked.kind, 'trackerIssue');
  assert.equal(picked.tracker, 'sh.abstract.jira');
  assert.equal(picked.trackerName, 'Jira');
  assert.deepEqual([picked.data, picked.size, picked.path], ['', 0, null]);
});

test('a sent tracker issue settles its pending message', () => {
  const attachment = { id: 'a1', kind: 'trackerIssue', title: 'Checkout retries twice', reference: 'SHOP-42', tracker: 'sh.abstract.jira' };
  const pending = [{ id: 'm1', text: 'Fix this', attachments: [attachment], afterSeq: 0, status: 'accepted' }];
  const raw = 'Fix this\n\n<attachment kind="trackerIssue" tracker="sh.abstract.jira" label="SHOP-42 Checkout retries twice" target="https://example.atlassian.net/browse/SHOP-42">\nJira issue SHOP-42\n</attachment>';
  assert.deepEqual(visiblePhoneMessages(pending, [{ seq: 1, line: { stream: 'user', line: raw } }]), []);
});

test('sent messages show their attachments as chips, with the tracker that found each', () => {
  const raw = 'Fix this\n\n<attachment kind="trackerIssue" tracker="sh.abstract.jira" label="SHOP-42 Checkout &quot;retries&quot;" target="https://example.atlassian.net/browse/SHOP-42">\nbody\n</attachment>\n\n<attachment kind="linearIssue" label="ENG-7 Old one">\nbody\n</attachment>\n\n<attachment kind="pullRequest" label="#12 Derive status">\nbody\n</attachment>';
  const { text, chips } = links.splitAttachments(raw);
  assert.equal(text, 'Fix this');
  assert.deepEqual(chips.map(chip => [chip.kind, chip.label, chip.tracker]), [
    ['trackerIssue', 'SHOP-42 Checkout "retries"', 'sh.abstract.jira'],
    ['trackerIssue', 'ENG-7 Old one', 'sh.abstract.linear'],
    ['pullRequest', '#12 Derive status', null],
  ]);
  assert.deepEqual(links.splitAttachments('plain'), { text: 'plain', chips: [] });
});

test('icons are kept per version and the chat shows its linked tracker’s key', () => {
  links.rememberIcons({ trackers: [jira, linear], linked: true, githubIssues: false, pullRequests: false });
  assert.deepEqual(links.knownIconVersions(), { 'sh.abstract.jira': '1.1.0' });
  assert.equal(links.trackerIcon('sh.abstract.jira').template, false);
  assert.equal(links.trackerIcon('sh.abstract.linear'), null);
  assert.deepEqual(links.linkedTrackerPills({ trackers: [jira], linked: true }).map(pill => pill.label), ['SHOP']);
  assert.deepEqual(links.linkedTrackerPills({ trackers: [unlinked(jira)], linked: false }), []);
});
