import { expect, mock, test } from 'claude-code/testing'
import { axis, insights, k, modelName, money } from '../hooks/register.js'

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
      `  🔀 Proxy State: ${ESC}[32mPRIMARY (oauth)${ESC}[0m\n` +
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
  expect(tips.some((t) => t.startsWith('Context grows about 2k a turn'))).toBe(true)
  expect(tips.some((t) => t.startsWith('This session has cost 32×'))).toBe(true)
  expect(tips.some((t) => t.startsWith('A quiet day: 8%'))).toBe(true)
  expect(tips.some((t) => t.startsWith('All sessions together are burning $7.28/hr (high)'))).toBe(true)
  expect(tips.some((t) => t.startsWith('wordpress-cyber-devtools is 64%'))).toBe(true)
  // Six at most: the busiest hour is the least urgent and is the one left out.
  expect(tips.length).toBe(6)
  expect(insights(doc({ projects: [] }), NOW).some((t) => t.text.startsWith('Your busiest hour is usually 10:00'))).toBe(true)
  const big = doc({ session: { ...doc().session, ctx: 450_000 } })
  expect(insights(big, NOW)[0].text).toContain('past the 400k restart line')
  const quiet = doc({ session: { ...doc().session, cost: 4 }, block: { active: false }, today: {}, projects: [], hourly_avg: null, turns: null })
  expect(insights(quiet, NOW)).toEqual([])
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
