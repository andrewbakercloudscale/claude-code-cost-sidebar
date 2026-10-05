import { expect, mock, test } from 'claude-code/testing'
import { axis, insights, k, layoutOf, modelName, money, relayout } from '../hooks/register.js'

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
    today: { cost: 6.7, tier: 'green', pred: 23.21, pred_tier: 'green', unpriced: '', typical_so_far: 80 },
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
function stubs(on, files: Array<object | null>, runs: string[][] = [], store: Record<string, unknown> = {}, opened: object[] = []) {
  const clock = mock.clock(on, { now: NOW * 1000 })
  mock.env(on, { HOME: '/Users/me' })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('command.register', () => ({ value: undefined }))
  on('ui.open', ($, e) => { opened.push(e); return { value: { isPlaced: true } } })
  on('ui.toast', () => ({ value: undefined }))
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
  // This session is marked among today's top sessions.
  expect(await ui.find({ type: 'Text', text: / ◀$/ })).toBeDefined()
  // The panel's own rows keep the panel's colours.
  expect((await ui.find({ type: 'Text', text: /^PRIMARY \(oauth\)$/ })).props.color).toBe('ansi256(2)')
  expect(await ui.find({ type: 'Text', text: /^  1039 Opus 5\.5/ })).toBeDefined()
  // Directly under the session's graphs, above Today, so it is on screen.
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn.indexOf('1039 Opus 5.5')).toBeGreaterThan(drawn.indexOf('This session'))
  expect(drawn.indexOf('1039 Opus 5.5')).toBeLessThan(drawn.indexOf('"Today"'))
  // Most specific first: session, today, 30 days, projects, set-up.
  const at = (x: string) => drawn.indexOf(x)
  expect(at('Context grows')).toBeGreaterThan(at('This session'))
  expect(at('Context grows')).toBeLessThan(at('"Today"'))
  expect(at('Quiet:')).toBeGreaterThan(at('"Today"'))
  expect(at('"Sessions today"')).toBeGreaterThan(at('Quiet:'))
  expect(at('"Last 30 days"')).toBeGreaterThan(at('"Sessions today"'))
  expect(at('"Projects"')).toBeGreaterThan(at('"Last 30 days"'))
  expect(at('Busiest hour')).toBeGreaterThan(at('"Projects"'))
  expect(at('Proxy State')).toBeGreaterThan(at('Busiest hour'))
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
  expect(tips.some((t) => t.startsWith('Context grows 2k/turn'))).toBe(true)
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
  expect(s[0].text).toContain('past the 400k restart line')
  const big = doc({ session: { ...doc().session, ctx: 450_000 } })
  expect(insights(big, NOW)[0].text).toContain('past the 400k restart line')
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

test('without Claude Burst there is no button and no Burst card', async ($, on) => {
  stubs(on, [doc({ burst: null })])
  let asked = 0
  on('http.fetch', () => { asked++; return { deny: 'not expected' } })
  await start($)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ key: 'burst' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'Claude Burst' })).toBeUndefined()
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

test('with Claude Burst, a card under the session shows the route, a standing problem and the context it sends by part', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  const urls: string[] = []
  on('http.fetch', ($, e) => {
    urls.push(e.url)
    return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(mod({ problems: [{ id: 'p', kind: 'keep-awake', severity: 'warn', title: 'Keep-awake turned off', ts: 1 }] })) } }
  })
  await start($)
  expect(urls[0]).toBe('http://127.0.0.1:7788/api/mod?session=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeb598c&since=' + NOW)
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '⚡ PRIMARY', color: 'green' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Keep-awake turned off', color: 'yellow' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '70k/300k 23%' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /CC holds 620k$/, color: 'yellow' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^█+$/, color: 'green' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Tool results 30k' })).toBeDefined()
  // A part with nothing in it takes no room in the legend.
  expect(await ui.find({ type: 'Text', text: /^MCP tools/ })).toBeUndefined()
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn.indexOf('"Claude Burst"')).toBeGreaterThan(drawn.indexOf('"This session"'))
  expect(drawn.indexOf('"Claude Burst"')).toBeLessThan(drawn.indexOf('"Turns"'))
})

test('the Burst card says so on the secondary, mid-compaction, and when the dashboard stops answering', async ($, on) => {
  const clock = stubs(on, [doc({ burst: BURST })])
  let answer: object | null = mod({ route: 'SECONDARY', overflow: true, session: { session: 'S', context: 310_000, state: 'summarising', compact_at: 300_000 } })
  on('http.fetch', () => (answer ? { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(answer) } } : { deny: 'connection refused' }))
  await start($)
  let ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '⚡ SECONDARY', color: 'yellow' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '  summarising' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '310k/300k 100%', color: 'red' })).toBeDefined()
  await ui.unmount()
  answer = null
  await clock.advance(5000)
  ui = await $.ui.mount(PANE)
  expect((await ui.find({ type: 'Text', text: /^⚡ Burst down/ })).props.color).toBe('red')
})

test('/usage-panel hide burst takes the Burst card away', async ($, on) => {
  stubs(on, [doc({ burst: BURST })])
  on('http.fetch', () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify(mod()) } }))
  await start($)
  await $.command.run({ command: 'usage-panel', args: 'hide burst' })
  const ui = await $.ui.mount(PANE)
  expect(await ui.find({ type: 'Text', text: '⚡ PRIMARY' })).toBeUndefined()
})

test('sections can be hidden, shown and moved, and the layout is kept', async ($, on) => {
  const saved: Record<string, unknown> = {}
  stubs(on, [doc()], [], saved)
  await start($)
  // A layout change redraws the pane, so each look is a fresh mount.
  const look = async () => { const ui = await $.ui.mount(PANE); const d = JSON.stringify(await ui.drawn()); await ui.unmount(); return d }
  const order = async () => { const d = await look(); return ['"This session"', '"Today"', '"Last 30 days"'].map((x) => d.indexOf(x)) }
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
    order: ['days', 'projects', 'session', 'burst', 'turns', 'today', 'sessions'],
    hidden: ['turns'],
  })
  expect(relayout(null, 'hide', 'nope')).toContain('Sections: session')
  expect((relayout(null, 'down', 'session') as any).order.slice(0, 2)).toEqual(['burst', 'session'])
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
