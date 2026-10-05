import { expect, mock, test } from 'claude-code/testing'
import { axis, insights, k, layoutOf, limitsOf, modelName, money, pie, planOf, relayout, share } from '../hooks/register.js'

const PANE = {
  plugin: 'usage-panel',
  component: 'Pane',
  surface: 'terminal',
  requestId: 'usage',
  viewport: { columns: 160, rows: 50 },
  props: { title: 'Usage', isFocused: false, bodyColumns: 54, placement: 'dock', scroll: { offset: 0, bodyRows: 48 }, view: {} },
} as const

const NOW = 1_791_187_000
const ESC = '\x1b'

function turns(n: number, from = 100_000, step = 2_000) {
  const out = []
  for (let i = 0; i < n; i++) out.push([1000 + i, from + i * step, step, 98.5, 0.05, NOW - (n - i) * 60, false])
  return out
}

function doc(over: Record<string, unknown> = {}) {
  return {
    v: 1, at: NOW - 4, slow_at: NOW - 30, refresh: 10, slow_refresh: 120,
    sid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c',
    session: {
      model: 'Opus 5.5', model_id: 'claude-opus-5-5', model_tier: 'cyan', folder: 'claude-burst', folder_spend: 742,
      cost: 170.88, tier: 'red', rate: 2.5, rate_tier: 'green', started: NOW - 86400, avg_session: 5.38,
      ctx: 205_818, win: 1_000_000, ctx_tier: 'green', compacting: false, restart_tokens: 400_000,
    },
    today: { cost: 6.7, tier: 'green', pred: 23.21, pred_tier: 'green', unpriced: '', typical_so_far: 80, turns: 80, turns_usd: 6.4 },
    block: { active: true, cost: 6.7, cph: 7.28, rem: 244, label: 'High', tier: 'red' },
    days30: { spend: 5363, prev: 159, tier: 'red', avg: 185, prev_avg: 5.5, avg_tier: 'red' },
    week: 95.4, month: 455.6,
    daily: Array.from({ length: 30 }, (_, i) => ({
      d: '2026-09-' + String(6 + i).padStart(2, '0'), cost: i === 12 ? 600 : 150, tokens: 1e6,
      models: { 'claude-opus-5-5': i === 12 ? 580 : 140, 'claude-sonnet-5': i === 12 ? 20 : 10 },
    })),
    hourly_avg: Array.from({ length: 24 }, (_, h) => (h === 10 ? 22.46 : h >= 8 && h <= 18 ? 15 : 2)),
    projects: [{ name: 'wordpress-cyber-devtools', cost: 1497 }, { name: 'claude-burst', cost: 711 }, { name: 'tools', cost: 120 }],
    top: [{ sid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c', cost: 4.98, tokens: 11e6, last: '2026-10-05T07:45:28.479Z' }, { sid: 'ffffffff-0000-1111-2222-333333312345', cost: 1.2, tokens: 2e6, last: '2026-10-05T06:00:00Z' }],
    turns: { turns: turns(40), markers: [], avg_delta: 3000 },
    summary:
      `  🔀 Proxy State: ${ESC}[32mPRIMARY (oauth)${ESC}[0m ${ESC}[1;38;2;0;0;0;48;2;125;249;255m[View]${ESC}[0m\n` +
      `  📜 License: ${ESC}[36mMax (20x)${ESC}[0m`,
    table:
      `  ${ESC}[36mTurn ${ESC}[0m${ESC}[36mModel     ${ESC}[0m\n` +
      `  1039 Opus 5.5    ${ESC}[32m178k${ESC}[0m (+2k)   99%   $0.05`,
    errors: [],
    thresholds: { ctx_yellow: 30, ctx_red: 50, ctx_purple: 70, burn_yellow: 3, burn_red: 6, tier_yellow_mult: 1.5, tier_red_mult: 2 },
    ...over,
  }
}

// Answers everything the mod calls. `files` is what fs.read returns for the
// session's JSON on each read, in turn; null is no file yet.
function stubs(on, files: Array<object | null>, runs: string[][] = [], store: Record<string, unknown> = {}, opened: object[] = [], toasts: string[] = []) {
  const clock = mock.clock(on, { now: NOW * 1000 })
  mock.env(on, { HOME: '/Users/me' })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('command.register', () => ({ value: undefined }))
  on('ui.open', ($, e) => { opened.push(e); return { value: { isPlaced: true } } })
  on('ui.toast', ($, e) => { toasts.push(JSON.stringify(e)); return { value: undefined } })
  on('store.get', ($, e) => (e.key in store ? { value: store[e.key] } : { value: undefined }))
  on('store.set', ($, e) => { store[e.key] = e.value; return { value: undefined } })
  on('process.run', ($, e) => { runs.push(e.argv); return { value: { exitCode: 0, stdout: 'started\n', stderr: '' } } })
  let i = 0
  on('fs.read', ($, e) => {
    if (!e.path.endsWith('/mod/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c.json')) return { deny: 'no such file' }
    const f = files[Math.min(i++, files.length - 1)]
    return f === null ? { deny: 'no such file' } : { value: JSON.stringify(f) }
  })
  return clock
}

async function start($) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
}

test('a new session starts the headless panel for itself and opens the sidebar', async ($, on) => {
  const runs: string[][] = []
  const opened: object[] = []
  stubs(on, [doc()], runs, {}, opened)
  await start($)
  expect(runs[0]).toEqual(['/Users/me/.local/bin/ccusage-panel-mod-start', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c', '/work'])
  expect(opened.length).toBe(1)
  expect(opened[0]).toMatchObject({ id: 'usage', title: 'Usage', columns: 58 })
  // Opened beside the session, not over it: no focus taken.
  expect((opened[0] as { focus?: boolean }).focus).toBeUndefined()
})

test('unpinned, a session does not open it; /usage pin puts it back', async ($, on) => {
  const opened: object[] = []
  const store: Record<string, unknown> = { pinned: false }
  stubs(on, [doc()], [], store, opened)
  await start($)
  expect(opened.length).toBe(0)
  await $.command.run({ command: 'usage-panel', args: 'pin' })
  expect(store.pinned).toBe(true)
  expect(opened.length).toBe(1)
  await $.command.run({ command: 'usage-panel', args: 'unpin' })
  expect(store.pinned).toBe(false)
  await $.command.run({ command: 'usage-panel', args: '' })
  expect(opened[opened.length - 1]).toMatchObject({ id: 'usage', focus: true })
})

test('the sidebar draws the session, today, 30 days, projects, top sessions and the panel rows', async ($, on) => {
  stubs(on, [doc()])
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '◆ Usage' })).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /^\$170\.88$/ })).props.color).toBe('red')
  expect((await ui.find({ type: 'Text', text: /^Opus 5\.5$/ })).props.color).toBe('cyan')
  expect(await ui.find({ type: 'Text', text: '206k/1M 21%' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Last 30 days' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^\$5,363$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^wordpress-cyber-devtools/ })).toBeDefined()
  // Beside Turns: today's average cost per API reply, and the burn rate, both for all sessions.
  expect(JSON.stringify(await ui.drawn())).toContain('"  Avg API: $0.08  All: $7.28/hr"')
  // This session is marked among today's top sessions.
  expect(await ui.find({ type: 'Text', text: / ◀$/ })).toBeDefined()
  // The panel's own rows keep the panel's colours.
  expect((await ui.find({ type: 'Text', text: /^PRIMARY \(oauth\)$/ })).props.color).toBe('ansi256(2)')
  expect(await ui.find({ type: 'Text', text: /^  1039 Opus 5\.5/ })).toBeDefined()
  // Directly under the session's graphs, above Today, so it is on screen.
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn.indexOf('1039 Opus 5.5')).toBeGreaterThan(drawn.indexOf('"Session:"'))
  expect(drawn.indexOf('1039 Opus 5.5')).toBeLessThan(drawn.indexOf('"This Mac"'))
  // Most specific first: session, this Mac, today, 30 days, projects.
  const at = (x: string) => drawn.indexOf(x)
  expect(at('Grows 2k/turn')).toBeGreaterThan(at('"Session:"'))
  expect(at('Grows 2k/turn')).toBeLessThan(at('"Today"'))
  expect(at('Quiet:')).toBeGreaterThan(at('"Today"'))
  expect(at('"Sessions today"')).toBeGreaterThan(at('Quiet:'))
  expect(at('"Last 30 days"')).toBeGreaterThan(at('"Sessions today"'))
  expect(at('"Projects"')).toBeGreaterThan(at('"Last 30 days"'))
  expect(at('Busiest hour')).toBeGreaterThan(at('"Projects"'))
  // This Mac is third, under the turn table and above the charts.
  expect(at('Proxy State')).toBeGreaterThan(at('1039 Opus 5.5'))
  expect(at('Proxy State')).toBeLessThan(at('"Today"'))
  expect(await ui.find({ type: 'Text', text: /^178k$/ })).toBeDefined()
  // Graphs: the 30-day bars mark the outlier day red.
  expect(await ui.find({ type: 'Text', text: /█/, color: 'red' })).toBeDefined()
})

test('before the first figures, the sidebar says it is starting', async ($, on) => {
  stubs(on, [null])
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'Starting the usage panel for this session…' })).toBeDefined()
})

test('a session with no reply yet says so instead of drawing zeros', async ($, on) => {
  stubs(on, [doc({ session: { model: '', cost: null, ctx: null, win: null }, turns: null })])
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'No reply yet: the figures start with the first one.' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^model unknown/ })).toBeUndefined()
})

test('before the first reply, "Unknown" and $0.00 are not drawn as readings', async ($, on) => {
  stubs(on, [doc({ session: { ...doc().session, model: 'Unknown', cost: 0, rate: 0, ctx: null }, turns: { turns: [], markers: [], avg_delta: 0 } })])
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'No reply yet: the figures start with the first one.' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Unknown$/ })).toBeUndefined()
})

test('a feed that has stopped says so', async ($, on) => {
  stubs(on, [doc({ at: NOW - 600 })])
  await start($)
  const ui = await $.ui.mount(PANE)
  expect((await ui.find({ type: 'Text', text: /^stopped 10m ago$/ })).props.color).toBe('red')
})

test('the feed is kept alive every 30 seconds and the file re-read every 5', async ($, on) => {
  const runs: string[][] = []
  const clock = stubs(on, [doc(), doc({ session: { ...doc().session, cost: 171.5 } })], runs)
  await start($)
  await clock.advance(5000)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: /^\$171\.50$/ })).toBeDefined()
  await ui.unmount()
  await clock.advance(25000)
  expect(runs.length).toBe(2)
})

test('insights say what matters and nothing when there is nothing', () => {
  const tips = insights(doc(), NOW).map((t) => t.text)
  expect(tips.some((t) => t.startsWith('Grows 2k/turn: amber (400k) in ~'))).toBe(true)
  expect(tips.some((t) => t.startsWith('32× your average session'))).toBe(true)
  expect(tips.some((t) => t.startsWith('Quiet: 8%'))).toBe(true)
  expect(tips.some((t) => t.startsWith('Burning $7.28/hr (high)'))).toBe(true)
  expect(tips.some((t) => t.startsWith('wordpress-cyber-devtools: 64%'))).toBe(true)
  expect(tips.some((t) => t.startsWith('Busiest hour: 10:00'))).toBe(true)
  // Each insight belongs to the block it is about.
  const scopes = insights(doc(), NOW).map((t) => t.scope)
  expect(scopes).toEqual(['session', 'session', 'session', 'today', 'today', 'general', 'general'])
  // Three at most per block, most urgent first.
  const crowded = doc({ session: { ...doc().session, ctx: 450_000, avg_session: 1 }, turns: { turns: turns(40, 100_000, 2_000).map((x, i) => (i === 39 ? [x[0], x[1], 30_000, 60, 2.5, x[5], false] : [x[0], x[1], x[2], 60, x[4], x[5], x[6]])), markers: [], avg_delta: 3000 } })
  const s = insights(crowded, NOW).filter((t) => t.scope === 'session')
  expect(s.length).toBe(3)
  expect(s[0].text).toBe('Getting expensive: every turn re-sends 450k. /compact, or /clear at a break in the work.')
  const big = doc({ session: { ...doc().session, ctx: 450_000 } })
  expect(insights(big, NOW)[0].tier).toBe('yellow')
  // Past 70% of the window it is red, and the bands follow the model's window.
  const huge = insights(doc({ session: { ...doc().session, ctx: 720_000 } }), NOW)[0]
  expect([huge.tier, huge.text]).toEqual(['red', 'Wasteful: every turn re-sends 720k. /compact now, or /clear and start fresh.'])
  const small = insights(doc({ session: { ...doc().session, ctx: 90_000, win: 200_000 } }), NOW)[0]
  expect(small.text).toContain('Getting expensive: every turn re-sends 90k.')
  // With Claude Burst the context is Burst's to manage: when it will compact.
  const withBurst = insights(big, NOW, null, null, { down: false, mod: mod() }).filter((t) => t.scope === 'session').map((t) => t.text)
  expect(withBurst.some((t) => t.includes('Getting expensive'))).toBe(false)
  expect(withBurst).toContain('Grows 2k/turn: Auto Compact in ~115 turns.')
  const quiet = doc({ session: { ...doc().session, cost: 4 }, block: { active: false }, today: {}, projects: [], hourly_avg: null, turns: null })
  expect(insights(quiet, NOW)).toEqual([])
})

test('with Claude Burst, a button opens its dashboard, or its console when the dashboard is down', async ($, on) => {
  const runs: string[][] = []
  const burst = { dashboard: 'http://127.0.0.1:7788/', console: 'http://127.0.0.1:7789/' }
  stubs(on, [doc({ burst })], runs)
  let up = true
  on('http.fetch', () => (up ? { value: { status: 200, ok: true, headers: {}, text: '' } } : { deny: 'connection refused' }))
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ key: 'burst' })).toBeDefined()
  // The panel's own [View] text is not drawn beside it: it would not click.
  expect(await ui.find({ type: 'Text', text: /^\[View\]$/ })).toBeUndefined()
  await ui.press({ key: 'burst' })
  expect(runs[runs.length - 1]).toEqual(['open', 'http://127.0.0.1:7788/'])
  up = false
  await ui.press({ key: 'burst' })
  expect(runs[runs.length - 1]).toEqual(['open', 'http://127.0.0.1:7789/'])
})

test('without Claude Burst there is no button, and the ctx bar is the panel\'s own', async ($, on) => {
  stubs(on, [doc({ burst: null })])
  let asked = 0
  on('http.fetch', () => { asked++; return { deny: 'not expected' } })
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ key: 'burst' })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: '206k/1M 21%' })).props.color).toBe('green')
  // Its two ticks are named in this model's tokens.
  expect(await ui.find({ type: 'Text', text: 'expensive from 400k' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'wasteful from 700k' })).toBeDefined()
  expect(asked).toBe(0)
})

const BURST = { dashboard: 'http://127.0.0.1:7788/', console: 'http://127.0.0.1:7789/' }

function mod(over: Record<string, unknown> = {}) {
  return {
    version: '0.13.0', route: 'PRIMARY', overflow: false, primary_failing: 0, today_usd: 1, today_requests: 2,
    session: {
      session: 'S', context: 70_000, state: 'ok', compact_at: 300_000, raw: 620_000,
      parts: [{ name: 'System prompt', tokens: 6000 }, { name: 'System tools', tokens: 14_000 }, { name: 'MCP tools', tokens: 0 }, { name: 'Messages', tokens: 20_000 }, { name: 'Tool results', tokens: 30_000 }],
    },
    alerts: [{ id: 'a', ts: 1 }], problems: [], ...over,
  }
}

test('with Claude Burst the session has one ctx bar: what Burst sends, by part, in the model\'s window, with its limits marked', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  const urls: string[] = []
  on('http.fetch', ($, e) => {
    urls.push(e.url)
    return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(mod({ problems: [{ id: 'p', kind: 'keep-awake', severity: 'warn', title: 'Keep-awake turned off', ts: 1 }] })) } }
  })
  await start($)
  expect(urls[0]).toBe('http://127.0.0.1:7788/api/mod?session=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c&since=' + NOW)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '70k/1M 7%' })).toBeDefined()
  // Once: the panel's own gauge against the model's window is not drawn too.
  expect(await ui.find({ type: 'Text', text: '206k/1M 21%' })).toBeUndefined()
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn.split('"ctx   "').length - 1).toBe(1)
  expect(await ui.find({ type: 'Text', text: /^█+$/, color: 'green' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Tool results 30k' })).toBeDefined()
  // Largest first, in the bar and in the legend.
  const at = (x: string) => drawn.indexOf(x)
  expect(at('Tool results 30k')).toBeLessThan(at('Messages 20k'))
  expect(at('Messages 20k')).toBeLessThan(at('System tools 14k'))
  expect(at('System tools 14k')).toBeLessThan(at('System prompt 6k'))
  // The room left before Burst compacts has its own colour and is named, last.
  expect(await ui.find({ type: 'Text', text: /^█+$/, color: 'white' })).toBeDefined()
  expect(at('Free 930k')).toBeGreaterThan(at('System prompt 6k'))
  // The bar is the model's whole window; where Burst compacts is a line on
  // it, named underneath.
  // A thin red line and an arrow at it, on the bar's own colour, so the bar
  // is not cut into bands.
  expect(drawn).toContain('{"color":"red","backgroundColor":"white"},"children":["▕"]')
  expect(drawn).toContain('{"color":"red","backgroundColor":"white"},"children":["◀"]')
  expect(drawn).toContain('"Burst compacts at 300k"')
  expect(drawn).not.toContain('warns at')
  // A part with nothing in it takes no room in the legend.
  expect(await ui.find({ type: 'Text', text: /^MCP tools/ })).toBeUndefined()
  // What Claude Code holds beyond that is the tool working: one line, never a warning.
  expect(await ui.find({ type: 'Text', text: 'Claude Code Cache Size: 620k', color: 'ansi256(208)' })).toBeDefined()
  // The bar is in the session card; a standing problem is with Proxy State.
  expect(drawn.indexOf('70k/1M 7%')).toBeLessThan(drawn.indexOf('"Turns"'))
  expect(await ui.find({ type: 'Text', text: 'Keep-awake turned off', color: 'yellow' })).toBeDefined()
  expect(drawn.indexOf('Keep-awake turned off')).toBeGreaterThan(drawn.indexOf('Proxy State'))
})

test('before Burst has the breakdown by part, the bar still has the red limit line on white', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  on('http.fetch', () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify(mod({ route: 'PRIMARY', session: { session: 'S', context: 147_000, state: 'ok', compact_at: 300_000 } })) } }))
  await start($)
  const ui = await $.ui.mount(PANE)
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn).toContain('{"color":"red","backgroundColor":"white"},"children":["▕"]')
  expect(drawn).toContain('{"color":"red","backgroundColor":"white"},"children":["◀"]')
  // The used share is one block, where the parts would be.
  expect(drawn.slice(drawn.indexOf('"ctx   "'), drawn.indexOf('147k/1M 15%'))).not.toContain('░')
})

test('over the limit the bar is red, a compaction under way is named, and a silent dashboard gives the panel gauge back', async ($, on) => {
  const clock = stubs(on, [doc({ burst: BURST })])
  let answer: object | null = mod({ route: 'SECONDARY', overflow: true, session: { session: 'S', context: 310_000, state: 'summarising', compact_at: 300_000 } })
  on('http.fetch', () => (answer ? { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(answer) } } : { deny: 'connection refused' }))
  await start($)
  let ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '310k/1M 31%', color: 'red' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '⟳ summarising' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Free/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /^Claude Code Cache Size/ })).toBeUndefined()
  await ui.unmount()
  // Once it is done there is no line left saying so for the rest of the session.
  answer = mod({ route: 'SECONDARY', session: { session: 'S', context: 64_000, state: 'compacted', compact_at: 300_000 } })
  await clock.advance(5000)
  ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: /compacted/ })).toBeUndefined()
  await ui.unmount()
  answer = null
  await clock.advance(5000)
  ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '⚡ Burst dashboard not answering', color: 'red' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '206k/1M 21%' })).toBeDefined()
})

test('sections can be hidden, shown and moved, and the layout is kept', async ($, on) => {
  const saved: Record<string, unknown> = {}
  stubs(on, [doc()], [], saved)
  await start($)
  // A layout change redraws the pane, so each look is a fresh mount.
  const look = async () => { const ui = await $.ui.mount(PANE); const d = JSON.stringify(await ui.drawn()); await ui.unmount(); return d }
  const order = async () => { const d = await look(); return ['"Session:"', '"Today"', '"Last 30 days"'].map((x) => d.indexOf(x)) }
  await $.command.run({ command: 'usage-panel', args: 'hide today' })
  expect((await order())[1]).toBe(-1)
  expect(await look()).toContain('Hidden: today')
  expect((saved.layout as any).hidden).toEqual(['today'])
  await $.command.run({ command: 'usage-panel', args: 'show today' })
  await $.command.run({ command: 'usage-panel', args: 'top days' })
  const [s, td, dy] = await order()
  expect(dy).toBeLessThan(s)
  expect(s).toBeLessThan(td)
  await $.command.run({ command: 'usage-panel', args: 'reset' })
  const [s2, td2, dy2] = await order()
  expect(s2).toBeLessThan(td2)
  expect(td2).toBeLessThan(dy2)
})

test('a stored layout is made whole: unknown names go, new sections come back', () => {
  expect(layoutOf({ order: ['days', 'gone', 'session'], hidden: ['gone', 'turns'] })).toEqual({
    // A returning section goes back beside its default neighbour.
    order: ['days', 'projects', 'session', 'turns', 'mac', 'plan', 'savings', 'today', 'sessions'],
    hidden: ['turns'],
  })
  expect(relayout(null, 'hide', 'nope')).toContain('Sections: session')
  expect((relayout(null, 'down', 'session') as any).order.slice(0, 2)).toEqual(['turns', 'session'])
})

test('every part and the room left keep a cell on the bar, however small', () => {
  // 287k of 300k: 13k free is 1.5 cells of 34, and 1k of system prompt none.
  const w = share([151_000, 127_000, 5_000, 2_000, 1_000, 13_000], 34)
  expect(w.reduce((a, b) => a + b, 0)).toBe(34)
  expect(w.every((x) => x >= 1)).toBe(true)
  expect(w[5]).toBeGreaterThanOrEqual(1)
  expect(w[0]).toBeGreaterThan(w[1])
  // Nothing of a kind takes no cell; nothing at all draws nothing.
  expect(share([10, 0, 10], 4)).toEqual([2, 0, 2])
  expect(share([0, 0], 10)).toEqual([0, 0])
})

test('close to the limit, the session says what Burst will do, not "warning"', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  on('http.fetch', () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify(mod({ session: { ...mod().session, context: 287_000, state: 'warning' } })) } }))
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '! Close to the limit: Burst compacts at 300k.', color: 'yellow' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /warning/ })).toBeUndefined()
})

// Burst's dashboard, as far as the mod asks it: the session (/api/mod), recent
// replies with Anthropic's limit headers, the state and today's usage.
function reply(five: number, week: number, time = '2026-10-05T14:00:00+02:00') {
  return {
    time, status: 200,
    headers: {
      'anthropic-ratelimit-unified-5h-utilization': String(five), 'anthropic-ratelimit-unified-5h-reset': String(NOW + 6060),
      'anthropic-ratelimit-unified-7d-utilization': String(week), 'anthropic-ratelimit-unified-7d-reset': String(NOW + 3 * 86400),
      'anthropic-ratelimit-unified-grace-5h-utilization': '0.000', 'anthropic-ratelimit-unified-5h-status': 'allowed',
    },
  }
}

function dashboard(on, answers: { responses?: () => unknown, state?: unknown, usage?: unknown, session?: unknown }, urls: string[] = []) {
  on('http.fetch', ($, e) => {
    urls.push(e.url)
    const body = e.url.includes('/api/responses') ? (answers.responses ? answers.responses() : [])
      : e.url.includes('/api/state') ? (answers.state || {})
        : e.url.includes('/api/usage') ? (answers.usage || {})
          : (answers.session || mod())
    return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(body) } }
  })
}

test('the plan limits are read off the newest reply that carries them', () => {
  const found = limitsOf([{ time: '2026-10-05T13:00:00+02:00', headers: { 'content-type': 'text/event-stream' } }, reply(0.2, 0.3, '2026-10-05T12:00:00+02:00'), reply(0.42, 0.35, '2026-10-05T12:30:00+02:00')])
  // Shortest window first; the grace figure is not a limit.
  expect(found).toEqual([{ key: '5h', util: 0.42, reset: NOW + 6060 }, { key: '7d', util: 0.35, reset: NOW + 3 * 86400 }])
  expect(limitsOf([{ time: 'x', headers: {} }])).toBe(null)
  // Anything that is not the list of replies is no reading, not a crash.
  expect(limitsOf(mod())).toBe(null)
  expect(limitsOf(null)).toBe(null)
  expect(planOf(doc().summary)).toEqual({ label: 'Max (20x)', price: 200 })
  expect(planOf(`  📜 License: ${ESC}[36mPro${ESC}[0m`)).toEqual({ label: 'Pro', price: 20 })
  expect(planOf(`  📜 License: ${ESC}[36mTeam${ESC}[0m`)).toEqual({ label: 'Team', price: 0 })
  expect(planOf(`  📜 License: ${ESC}[33mAPI key (anthropic)${ESC}[0m`)).toBe(null)
  expect(planOf('')).toBe(null)
})

test('Plan Utilisation draws each limit with Claude Burst, and says where they come from without it', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  const urls: string[] = []
  dashboard(on, { responses: () => [reply(0.42, 0.85)] }, urls)
  await start($)
  expect(urls.some((u) => u === 'http://127.0.0.1:7788/api/responses')).toBe(true)
  const ui = await $.ui.mount(PANE)
  const drawn = JSON.stringify(await ui.drawn())
  expect(await ui.find({ type: 'Text', text: 'Plan Utilisation' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ 42%  resets \d\d:\d\d \(1h41m\)$/ })).toBeDefined()
  // Past 80% the row is yellow; the weekly one resets on another day.
  expect((await ui.find({ type: 'Text', text: /^ 85%  resets (Sun|Mon|Tue|Wed|Thu|Fri|Sat) \d\d:\d\d$/ })).props.color).toBe('yellow')
  expect(drawn).toContain('"weekly"')
  expect(drawn).toContain(' at API rates this month ($200 plan)')
  // This Mac's rows start at the card's edge, like the rows under them.
  expect(drawn).toContain('"🔀 Proxy State: "')
  // Under This Mac, above Today.
  expect(drawn.indexOf('"Plan Utilisation"')).toBeGreaterThan(drawn.indexOf('Proxy State'))
  expect(drawn.indexOf('"Plan Utilisation"')).toBeLessThan(drawn.indexOf('"Today"'))
  await ui.unmount()
  await $.command.run({ command: 'usage-panel', args: 'hide plan' })
  const hidden = await $.ui.mount(PANE)
  expect(await hidden.find({ type: 'Text', text: 'Plan Utilisation' })).toBeUndefined()
})

test('the compaction limit is the one GetAutoCompactionThreshold gives for this folder, marked when it is learned', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  const urls: string[] = []
  on('http.fetch', ($, e) => {
    urls.push(e.url)
    const body = e.url.includes('/api/GetAutoCompactionThreshold')
      ? { folder: '/work', repo: 'work', threshold: 155_000, source: 'learned', intelligent: true, enabled: true, fixed: 300_000, floor: 100_000, target: 155_000, delay_minutes: 30, buffer_percent: 20, failures: { unpaid: 2, attempts: 28 } }
      : e.url.includes('/api/state') || e.url.includes('/api/responses') || e.url.includes('/api/usage') ? {}
        : mod({ session: { ...mod().session, context: 110_000, state: 'warning' } })
    return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(body) } }
  })
  await start($)
  // Asked by folder: the session's working directory.
  expect(urls).toContain('http://127.0.0.1:7788/api/GetAutoCompactionThreshold?folder=%2Fwork')
  const ui = await $.ui.mount(PANE)
  const drawn = JSON.stringify(await ui.drawn())
  // The gateway's answer for the folder, not the 300k the session's own figures carry.
  // A learned limit reads as automatic, in its own colour, with where it
  // comes from and how often a session may be compacted beside it.
  expect(await ui.find({ type: 'Text', text: 'Auto compacts at 155k', color: 'cyan' })).toBeDefined()
  expect(drawn).toContain('"learned for this repo, 20% buffer · max 1 per 30 min"')
  expect(drawn).not.toContain('compacts at 300k')
  expect(await ui.find({ type: 'Text', text: '! Close to the limit: Auto compacts at 155k.', color: 'yellow' })).toBeDefined()
})

test('Pauseless Compaction shows what Burst\'s compaction saved, what it cost, and this session\'s share', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  const stats = {
    compactions: 45, saved_usd: 298.47, summary_usd: 12.59, rewrite_usd: 9.83, net_usd: 276.05,
    tokens_not_resent: 1_492_358_786, largest_before: 945_748, largest_after: 60_359,
    sessions: [{ session: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c', net_usd: 3.19, compactions: 2 }, { session: 'other', net_usd: 9, compactions: 1 }],
    daily: [{ date: '2026-10-03', net_usd: 92.7, compactions: 11 }, { date: '2026-10-04', net_usd: 46.6, compactions: 6 }, { date: '2026-10-05', net_usd: 26.7, compactions: 6 }],
  }
  const state = { context: { window_days: 7, compaction: { warn_at_percent: 80 }, compaction_stats: stats }, today: { SecondaryRequests: 0 } }
  dashboard(on, { state })
  await start($)
  const ui = await $.ui.mount(PANE)
  const drawn = JSON.stringify(await ui.drawn())
  expect(await ui.find({ type: 'Text', text: 'Pauseless Compaction' })).toBeDefined()
  expect(drawn).toContain('"  last 7 days"')
  expect(drawn).toContain('{"bold":true,"color":"green"},"children":["$276"]')
  expect(drawn).toContain('"  45 compactions"')
  expect(drawn).toContain('"  $298.47"')
  expect(drawn).toContain('"  -$12.59"')
  expect(drawn).toContain('"   -$9.83"')
  expect(drawn).toContain('"1.49B tokens not re-sent, largest 946k → 60k"')
  // This session's own share, and no other's.
  expect(drawn).toContain('"2 compactions have saved "')
  expect(drawn).toContain('"$3.19"')
  expect(drawn).toContain('" this session"')
  // Under Plan Utilisation, above Today; and it can be hidden like the rest.
  expect(drawn.indexOf('"Pauseless Compaction"')).toBeGreaterThan(drawn.indexOf('"Plan Utilisation"'))
  expect(drawn.indexOf('"Pauseless Compaction"')).toBeLessThan(drawn.indexOf('"Today"'))
  await ui.unmount()
  await $.command.run({ command: 'usage-panel', args: 'hide savings' })
  const hidden = await $.ui.mount(PANE)
  expect(await hidden.find({ type: 'Text', text: 'Pauseless Compaction' })).toBeUndefined()
})

test('without Burst, or before Burst has compacted anything, there is no Pauseless Compaction card', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  dashboard(on, { state: { context: { compaction_stats: { compactions: 0, sessions: [], daily: [] } } } })
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'Pauseless Compaction' })).toBeUndefined()
})

test('a reading another session took is shown until this one has its own', async ($, on) => {
  // Burst lists its last 20 replies of any kind: a model reply is soon gone.
  const saved: Record<string, unknown> = { limits: [{ key: '5h', util: 0.3, reset: NOW + 6060 }] }
  const clock = stubs(on, [doc({ burst: BURST })], [], saved)
  let list: unknown[] = []
  dashboard(on, { responses: () => list })
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: /^ 30%  resets / })).toBeDefined()
  await ui.unmount()
  list = [reply(0.44, 0.35)]
  await clock.advance(15000)
  expect((saved.limits as any)[0].util).toBe(0.44)
  // And a poll that finds none keeps it.
  list = []
  await clock.advance(15000)
  const later = await $.ui.mount(PANE)
  expect(await later.find({ type: 'Text', text: /^ 44%  resets / })).toBeDefined()
})

test('without Claude Burst, Plan Utilisation shows the plan and no limits', async ($, on) => {
  stubs(on, [doc({ burst: null })])
  let asked = 0
  on('http.fetch', () => { asked++; return { deny: 'not expected' } })
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: 'Plan Utilisation' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /comes from Claude Burst/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /%  resets / })).toBeUndefined()
  expect(asked).toBe(0)
})

test('a plan limit that is close is toasted, once at 80% and once at 95%', async ($, on) => {
  const toasts: string[] = []
  const clock = stubs(on, [doc({ burst: BURST })], [], {}, [], toasts)
  let five = 0.5
  dashboard(on, { responses: () => [reply(five, 0.35)] })
  await start($)
  const limit = () => toasts.filter((t) => t.includes('Plan limit'))
  expect(limit().length).toBe(0)
  five = 0.81
  await clock.advance(60000)
  expect(limit().length).toBe(1)
  expect(limit()[0]).toContain('Plan limit: 81% of the 5h limit used, resets ')
  // The same level is not repeated.
  five = 0.9
  await clock.advance(60000)
  expect(limit().length).toBe(1)
  five = 0.96
  await clock.advance(60000)
  expect(limit().length).toBe(2)
  expect(limit()[1]).toContain('96% of the 5h limit')
  await clock.advance(120000)
  expect(limit().length).toBe(2)
})

test('insights from Claude Burst: the limit at this pace, what fills the context, the secondary', () => {
  const d = doc({ burst: BURST })
  // 60% of the 5-hour limit with 3h20m still to run: used up well before it resets.
  const limits = [{ key: '5h', util: 0.6, reset: NOW + 12000 }, { key: '7d', util: 0.35, reset: NOW + 3 * 86400 }]
  const extra = { saved: { net: 3.19, n: 2 }, secondary: { requests: 4, usd: 0.37, names: ['together'] } }
  const burst = { down: false, mod: mod({ session: { ...mod().session, context: 200_000, parts: [{ name: 'Tool results', tokens: 130_000 }, { name: 'Messages', tokens: 70_000 }] } }) }
  const tips = insights(d, NOW, limits, extra, burst)
  const text = (scope: string) => tips.filter((t) => t.scope === scope).map((t) => t.text)
  expect(text('plan').length).toBe(1)
  expect(text('plan')[0]).toMatch(/^At this pace the 5h limit is reached \d\d:\d\d \(1h07m\), 2h13m before it resets\.$/)
  expect(text('burst')).toEqual(['Tool results are 65% of the context sent.'])
  expect(text('today').some((t) => t === '4 requests went to the secondary today (together): $0.37 on top of the plan.')).toBe(true)
  // A limit that is gone says so; one barely started says nothing.
  const gone = insights(d, NOW, [{ key: '7d', util: 1, reset: NOW + 86400 }], null, null).filter((t) => t.scope === 'plan')
  expect(gone[0].text).toMatch(/^The weekly limit is used up: resets /)
  expect(insights(d, NOW, [{ key: '5h', util: 0.04, reset: NOW + 17000 }], null, null).filter((t) => t.scope === 'plan')).toEqual([])
})

test('a turn made dear by a pause that let the cache go is named as that', () => {
  const ts = turns(40).map((x, i) => (i === 39 ? [x[0], x[1], x[2], 4, 0.9, x[5] + 1500, false] : x))
  const tips = insights(doc({ turns: { turns: ts, markers: [], avg_delta: 3000 } }), NOW).map((t) => t.text)
  expect(tips.some((t) => t === 'Turn 1039 came after a 26m pause and read 4% from cache: $0.90 against a $0.05 median.')).toBe(true)
  // Once: the same turn is not also reported as an unexplained spike.
  expect(tips.filter((t) => t.includes('1039')).length).toBe(1)
  // A short gap is not a pause.
  const quick = turns(40).map((x, i) => (i === 39 ? [x[0], x[1], x[2], 4, 0.9, x[5], false] : x))
  expect(insights(doc({ turns: { turns: quick, markers: [], avg_delta: 3000 } }), NOW).some((t) => t.text.includes('pause'))).toBe(false)
})

test('the turn after a compaction is cyan on the cost chart and is not reported as a costly turn', async ($, on) => {
  // Turn 1035: the context falls from 168k to 60k and the turn costs 8x the median.
  const ts = turns(40).map((x, i) => (i >= 35 ? [x[0], 60_000 + (i - 35) * 2_000, i === 35 ? -108_000 : 2_000, i === 35 ? 19 : 98.5, i === 35 ? 0.4 : 0.05, x[5], false] : x))
  const d = doc({ turns: { turns: ts, markers: [], avg_delta: 3000 } })
  expect(insights(d, NOW).some((t) => t.text.includes('1035'))).toBe(false)
  // The same cost with no drop in context is still named.
  const plain = turns(40).map((x, i) => (i === 35 ? [x[0], x[1], x[2], x[3], 0.4, x[5], false] : x))
  expect(insights(doc({ turns: { turns: plain, markers: [], avg_delta: 3000 } }), NOW).some((t) => t.text.startsWith('Turn 1035: $0.40, 8× median'))).toBe(true)
  stubs(on, [d])
  await start($)
  const ui = await $.ui.mount(PANE)
  const drawn = JSON.stringify(await ui.drawn())
  const chart = drawn.slice(drawn.indexOf('"$/turn"'), drawn.indexOf('"cache "'))
  expect(chart).toContain('"color":"cyan"')
  expect(chart).not.toContain('"color":"red"')
})

test('the costliest turns today are listed under the top sessions, from any session', async ($, on) => {
  stubs(on, [doc({ top_turns: [
    { sid: 'ffffffff-0000-1111-2222-333333312345', folder: 'wordpress-cyber-devtools', turn: 212, cost: 6.81, ctx: 849_740, at: NOW - 3600 },
    { sid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c', folder: 'claude-burst', turn: 1031, cost: 2.1, ctx: 286_963, at: NOW - 600 },
  ] })])
  await start($)
  const ui = await $.ui.mount(PANE)
  const drawn = JSON.stringify(await ui.drawn())
  expect(await ui.find({ type: 'Text', text: 'Costliest turns today' })).toBeDefined()
  expect(drawn).toContain('"#212 "')
  expect(drawn).toContain('" $6.81"')
  // A long folder keeps its end, as the project rows do.
  expect(drawn).toContain('"…s-cyber-devtools"')
  expect(drawn.indexOf('"#212 "')).toBeLessThan(drawn.indexOf('"#1031"'))
  await ui.unmount()
})

test('a long folder beside the session id loses its start, not its end', async ($, on) => {
  stubs(on, [doc({ session: { ...doc().session, folder: 'claudecode-cost-usage-panel-with-a-long-name' } })])
  await start($)
  const ui = await $.ui.mount(PANE)
  const note = await ui.find({ type: 'Text', text: /^  \*b598c · …/ })
  expect(note.text.endsWith('-with-a-long-name')).toBe(true)
  // The heading and the note together fit the card.
  expect('Session:'.length + note.text.length).toBeLessThanOrEqual(50)
})

test('the models pie gives each slice its share of the disc, clockwise from the top', () => {
  const T = (children: any, props: any = {}) => ({ props, children: Array.isArray(children) ? children : [children] })
  const rows = pie(T, [['magenta', 50], ['blue', 25], ['yellow', 25]], 8) as any[]
  expect(rows.length).toBe(8)
  // Count quarters of a cell: a quadrant block is its colour's quarters on the other's.
  const quarters: Record<string, number> = {}
  const on = (ch: string) => ({ ' ': 0, '▘': 1, '▝': 1, '▖': 1, '▗': 1, '▀': 2, '▄': 2, '▌': 2, '▐': 2, '▞': 2, '▚': 2, '▛': 3, '▜': 3, '▙': 3, '▟': 3, '█': 4 } as any)[ch]
  for (const row of rows) for (const seg of row.children) for (const ch of seg.children[0]) {
    if (seg.props.color) quarters[seg.props.color] = (quarters[seg.props.color] || 0) + on(ch)
    if (seg.props.backgroundColor) quarters[seg.props.backgroundColor] = (quarters[seg.props.backgroundColor] || 0) + 4 - on(ch)
  }
  const all = quarters.magenta + quarters.blue + quarters.yellow
  expect(Math.abs(quarters.magenta / all - 0.5)).toBeLessThan(0.04)
  expect(Math.abs(quarters.blue / all - 0.25)).toBeLessThan(0.04)
  // The first slice starts at twelve o'clock and runs down the right side.
  const mid = rows[3].children
  expect(mid[mid.length - 1].props.color).toBe('magenta')
  // The rim is drawn in part cells, on the terminal's own background.
  expect(rows[0].children.some((g: any) => /[▗▖▄▟▙]/.test(g.children[0]) && !g.props.backgroundColor)).toBe(true)
  // Every row is as wide as the pie: twice its height in cells.
  for (const row of rows) expect(row.children.reduce((a: number, g: any) => a + g.children[0].length, 0)).toBe(16)
  expect(pie(T, [], 8)).toEqual([])
})

test('formatting', () => {
  expect(money(5363.4)).toBe('$5,363')
  expect(money(6.7, 2)).toBe('$6.70')
  expect(money(null)).toBe('--')
  expect(k(205818)).toBe('206k')
  expect(k(1_000_000)).toBe('1M')
  expect(modelName('claude-opus-5-5')).toBe('Opus 5.5')
  expect(modelName('claude-sonnet-5')).toBe('Sonnet 5')
  expect(modelName('claude-haiku-4-5-20251001')).toBe('Haiku 4.5')
  expect(axis(['0', '12', '23'], 10)).toBe('0   12  23')
})
