// Draws the README's screenshots of the usage sidebar.
//
// The pictures are the mod's own drawing: this imports panel() from
// mods/usage-panel/hooks/register.js, hands it made-up figures, turns the
// Box/Text tree it returns into HTML and photographs that with Playwright.
// So a change to the sidebar is a re-run away from being in the README:
//
//   PLAYWRIGHT=/path/to/node_modules/playwright node docs/render-screenshots.mjs
//
// (PLAYWRIGHT is only needed when `playwright` is not resolvable from here.)
// Every figure below is invented. Nothing is read from this Mac.

import { createRequire } from 'node:module'
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT || 'playwright')

// register.js is an ES module in a folder with no package.json, which node
// would load as CommonJS: import a copy named .mjs.
const tmp = mkdtempSync(join(tmpdir(), 'usage-panel-shots-'))
copyFileSync(join(here, '../mods/usage-panel/hooks/register.js'), join(tmp, 'register.mjs'))
const { panel } = await import(pathToFileURL(join(tmp, 'register.mjs')).href)

const WIDTH = 56 // the body of a 58-column sidebar
const ESC = '\x1b'
const NOW = Math.floor(new Date(2026, 9, 5, 14, 19, 5).getTime() / 1000)
const SID = '4c1d9a52-7b3e-4f60-9d2a-51c0b3ee7d21'

// ---- made-up figures ---------------------------------------------------------

// One session that grew to Burst's 300k limit and was compacted at turn 143.
// [turn, context, delta, cache hit %, cost, epoch, served by the secondary]
const COMPACTED_AT = 143
function allTurns(last) {
  const out = []
  let ctx = 152000
  for (let n = 97; n <= last; n++) {
    let delta = 1800 + ((n * 7919) % 2600)
    let hit = 96 + ((n * 31) % 4)
    let cost = Math.round((ctx * 0.5e-6 + delta * 6.25e-6 + 0.012) * 100) / 100
    if (n === COMPACTED_AT) {
      // The summary replaces the history: the context drops, and what is
      // left is written to the cache once.
      delta = 52000
      ctx = 64000
      hit = 19
      cost = 0.38
    } else {
      ctx += delta
    }
    out.push([n, ctx, delta, hit, cost, NOW - (last - n) * 95 - 20, false])
  }
  return out
}

const G = `${ESC}[32m`, Y = `${ESC}[33m`, B = `${ESC}[34m`, M = `${ESC}[35m`, R = `${ESC}[31m`, C = `${ESC}[36m`, X = `${ESC}[0m`
const kk = (n) => (n >= 1000 ? Math.round(n / 1000) + 'k' : String(n))

// The turn table as ccusage-panel.sh prints it: newest first, a compaction's
// rows between the turns it happened between.
function table(turns, marks) {
  const rows = [`  ${C}Turn ${X}${C}Model     ${X}${G}   Input (Δ)${X}${B} Cache${X}${R}    Cost${X}`]
  for (const m of marks.top || []) rows.push(m)
  for (let i = turns.length - 1; i >= 0 && rows.length < 13; i--) {
    const [n, ctx, delta, hit, cost] = turns[i]
    const prev = i > 0 ? turns[i - 1][1] : 0
    const shrank = prev && ctx < prev * 0.8
    const cell = shrank ? `${kk(ctx)} (-${kk(prev - ctx)})` : `${kk(ctx)} (+${kk(delta)})`
    const pad = ' '.repeat(Math.max(0, 12 - cell.length))
    // A turn that sent the whole conversation again: the rise in yellow,
    // and the same figure in the row under it.
    const again = marks.replayed && marks.replayed[n]
    const input = shrank ? `${G}${kk(ctx)}${X} (${G}-${kk(prev - ctx)}${X})` : again ? `${G}${kk(ctx)}${X} (+${Y}${kk(delta)}${X})` : `${G}${kk(ctx)}${X} (+${G}${kk(delta)}${X})`
    const cc = hit < 90 ? M : hit < 95 ? R : G
    // A compaction's turn is blue from end to end.
    if (shrank) rows.push(`  ${B}${String(n).padEnd(5)}${'Opus 5.5'.padEnd(10)}${pad}${cell}${(hit + '%').padStart(6)}${('$' + cost.toFixed(2)).padStart(8)}${X}`)
    else rows.push(`  ${String(n).padEnd(5)}${'Opus 5.5'.padEnd(10)}${pad}${input}${cc}${(hit + '%').padStart(6)}${X}${('$' + cost.toFixed(2)).padStart(8)}`)
    if (again) rows.push(`  ${Y}*** Replayed in full: ${kk(delta)} sent again ***${X}`)
    for (const m of (marks.under && marks.under[n]) || []) rows.push(m)
  }
  return rows.slice(0, 13).join('\n')
}

const STARTED = `  ${Y}*** Async Compaction Started ***${X}`
const PENDING = `  ${B}*** Async Compaction Pending (next prompt) ***${X}`
const FINISHED = `  ${G}*** Async Compaction Finished ($0.41) ***${X}`

const DAILY = [18, 31, 24, 22, 27, 26, 19, 14, 44, 46, 33, 21, 31, 12, 9, 48, 47, 41, 34, 28, 65, 11, 16, 24, 38, 29, 25, 39, 21, 31.4]

function doc(turns, marks, over = {}) {
  const last = turns[turns.length - 1]
  const cost = 14.62 + (last[0] - 149) * 0.16
  return {
    v: 1, at: NOW - 3, slow_at: NOW - 40, refresh: 10, slow_refresh: 120,
    sid: SID,
    session: {
      model: 'Opus 5.5', model_id: 'claude-opus-5-5', model_tier: 'cyan', folder: 'my-app', folder_spend: 212,
      cost, tier: 'yellow', rate: 3.1, rate_tier: 'yellow', started: NOW - 4 * 3600, avg_session: 6.1,
      ctx: last[1], win: 1000000, ctx_tier: 'green', compacting: false, restart_tokens: 400000,
    },
    today: { cost: 31.4, tier: 'green', pred: 44.9, pred_tier: 'green', unpriced: '', typical_so_far: 27, turns: 262, turns_usd: 31.4, cache_loss: 1.84, cache_loss_turns: 6, cache_loss_30: 12.4, cache_loss_days: 9 },
    block: { active: true, cost: 12.8, cph: 4.1, rem: 118, label: 'Elevated', tier: 'yellow' },
    days30: { spend: 806, prev: 733, tier: 'green', avg: 27.8, prev_avg: 24.4, avg_tier: 'green' },
    week: 118, month: 132,
    daily: DAILY.map((c, i) => {
      const day = new Date(2026, 8, 6 + i)
      const d = day.getFullYear() + '-' + String(day.getMonth() + 1).padStart(2, '0') + '-' + String(day.getDate()).padStart(2, '0')
      return { d, cost: c, tokens: c * 1e6, models: { 'claude-opus-5-5': c * 0.62, 'claude-sonnet-5-5': c * 0.3, 'claude-haiku-4-5-20251001': c * 0.08 } }
    }),
    hourly_avg: [0.2, 0.2, 0, 0, 0, 0, 0.3, 0.9, 2.6, 4.4, 5.1, 4.6, 3.9, 2.8, 4.3, 3.6, 3.1, 2.2, 1.4, 1.1, 0.9, 1.3, 1.0, 0.6],
    projects: [{ name: 'my-app', cost: 212 }, { name: 'api-server', cost: 169 }, { name: 'infra-terraform', cost: 121 }, { name: 'docs-site', cost: 58.2 }, { name: 'scratch', cost: 22.7 }],
    top: [
      { sid: SID, cost, tokens: 31e6, last: new Date(NOW * 1000).toISOString() },
      { sid: 'aaaaaaaa-0000-0000-0000-000000091b04', cost: 9.8, tokens: 19e6, last: new Date((NOW - 77 * 60) * 1000).toISOString() },
      { sid: 'aaaaaaaa-0000-0000-0000-00000000c7e2', cost: 4.31, tokens: 8e6, last: new Date((NOW - 219 * 60) * 1000).toISOString() },
    ],
    top_turns: [
      { sid: 'aaaaaaaa-0000-0000-0000-000000091b04', folder: 'api-server', turn: 61, cost: 1.92, ctx: 268000, at: NOW - 171 * 60, cache: 1, delta: 265000, gap: 1260, prev: 266000, out: 700 },
      { sid: SID, folder: 'my-app', turn: 118, cost: 0.84, ctx: 221000, at: NOW - 96 * 60, cache: 61, delta: 86000, gap: 40, prev: 135000, out: 900 },
      { sid: 'aaaaaaaa-0000-0000-0000-00000000c7e2', folder: 'infra-terraform', turn: 34, cost: 0.71, ctx: 143000, at: NOW - 247 * 60, cache: 97, delta: 3000, gap: 25, prev: 140000, out: 14000 },
      { sid: SID, folder: 'my-app', turn: 143, cost: 0.38, ctx: 64000, at: NOW - 21 * 60, cache: 4, delta: 61000, gap: 30, prev: 299000, out: 400 },
      { sid: 'aaaaaaaa-0000-0000-0000-000000091b04', folder: 'api-server', turn: 77, cost: 0.36, ctx: 291000, at: NOW - 104 * 60, cache: 99, delta: 2000, gap: 20, prev: 289000, out: 500 },
    ],
    turns: { turns, markers: [], avg_delta: 3000 },
    burst: { dashboard: 'http://127.0.0.1:7788/', console: 'http://127.0.0.1:7789/' },
    summary: `  🔀 Proxy State: ${G}PRIMARY (oauth)${X}\n  📜 License: ${C}Max (20x)${X}`,
    table: table(turns, marks),
    errors: [],
    thresholds: { ctx_yellow: 30, ctx_red: 50, ctx_purple: 70, burn_yellow: 3, burn_red: 6, tier_yellow_mult: 1.5, tier_red_mult: 2 },
    ...over,
  }
}

// What Claude Burst's dashboard says of the session: the context it sends,
// by part, against the limit it compacts at.
function burst(context, state, raw, problems = [], at = 300000) {
  const fixed = 2000 + 9000 + 6000 + 4000
  const rest = context - fixed
  return {
    down: false,
    mod: {
      route: 'PRIMARY', problems,
      session: {
        context, state, raw, compact_at: at, learned: at !== 300000,
        parts: [
          { name: 'System prompt', tokens: 2000 }, { name: 'System tools', tokens: 9000 }, { name: 'MCP tools', tokens: 6000 },
          { name: 'Memory files', tokens: 4000 }, { name: 'Messages', tokens: Math.round(rest * 0.7) }, { name: 'Tool results', tokens: Math.round(rest * 0.3) },
        ],
      },
    },
  }
}

// The plan's limits as Anthropic's replies report them (Burst keeps the
// latest), and what Burst's compaction has saved this session.
const LIMITS = [{ key: '5h', util: 0.82, reset: NOW + 118 * 60 }, { key: '7d', util: 0.58, reset: NOW + 2 * 86400 + 11 * 3600 + 41 * 60 }]
// And what used each limit, by project, with the last 7 days: led by a
// project other than the one that leads the 30.
const BY = (rows) => ({ rows: rows.map(([name, usd]) => ({ name, usd })), total: rows.reduce((a, r) => a + r[1], 0) })
const SAVED = {
  saved: { net: 2.84, n: 1 }, secondary: null, warn: 80,
  by: {
    '5h': BY([['my-app', 9.1], ['api-server', 2.9], ['infra-terraform', 0.8]]),
    '7d': BY([['api-server', 54.2], ['my-app', 41.6], ['infra-terraform', 12.3], ['docs-site', 6.1], ['scratch', 3.8]]),
  },
  week: { ...BY([['api-server', 54.2], ['my-app', 41.6], ['infra-terraform', 12.3], ['docs-site', 6.1], ['scratch', 3.8]]), repos: ['my-app', 'api-server', 'infra-terraform', 'docs-site', 'scratch'] },
  spent: 118.4,
  comp: {
    days: 7, n: 9, saved: 31.62, summary: 3.47, rewrite: 2.9, net: 24.45, tokens: 158400000, before: 300400, after: 61200,
    daily: [['2026-09-29', 2.1], ['2026-09-30', 4.6], ['2026-10-01', 3.2], ['2026-10-02', -0.4], ['2026-10-03', 6.9], ['2026-10-04', 5.21], ['2026-10-05', 2.84]].map(([d, net]) => ({ d, net, n: 1 })),
  },
}

const scenes = {}
{
  // Six turns after a compaction: the sidebar as it mostly looks.
  const t = allTurns(149)
  scenes.steady = { d: doc(t, { under: { 143: [FINISHED], 142: [STARTED] } }), b: burst(t[t.length - 1][1], 'ok', 320000), x: SAVED }
  scenes.problem = { d: scenes.steady.d, b: burst(t[t.length - 1][1], 'ok', 320000, [{ severity: 'warn', title: 'Keep-awake turned off' }]), x: SAVED }
}
{
  // Without Claude Burst: nothing compacts for you, so the context has only
  // grown. Past 40% of the window the bar is amber and says what to do.
  const t = allTurns(142).map((x) => [x[0], x[1] + 226000, x[2], x[3], Math.round((x[4] + 0.11) * 100) / 100, x[5], x[6]])
  const d = doc(t, {}, { burst: null, summary: `  📜 License: ${C}Max (20x)${X}` })
  d.session.cost = 31.07
  scenes.alone = { d, b: null }
}
{
  // Burst's Intelligent Compaction Mode chose a limit for this repository,
  // under the fixed 300k.
  const t = allTurns(113)
  scenes.intelligent = { d: doc(t, {}), b: burst(t[t.length - 1][1], 'ok', t[t.length - 1][1], [], 240000), x: { ...SAVED, auto: { at: 240000, source: 'learned', fixed: 300000, target: 240000, delay: 0, buffer: 0, lost: 0 } } }
}
{
  // Compacted by Burst more than once, and Claude Code still holds all of
  // it: over half the model's window, so the button is beside the figure.
  const t = allTurns(149)
  scenes.held = { d: doc(t, { under: { 143: [FINISHED], 142: [STARTED] } }), b: burst(t[t.length - 1][1], 'compacted', 539000), x: SAVED }
}
{
  // After a pause Anthropic no longer held the thread, and Claude Code sent
  // the whole conversation again: one turn's context rose by far more than
  // the turn wrote.
  const t = allTurns(120).map((x) => (x[0] < 118 ? x : [x[0], x[1] + 102000, x[0] === 118 ? 102000 + x[2] : x[2], x[0] === 118 ? 57 : x[3], x[0] === 118 ? 0.84 : x[4], x[5], x[6]]))
  scenes.replayed = { d: doc(t, { replayed: { 118: true } }), b: burst(t[t.length - 1][1], 'ok', t[t.length - 1][1]) }
}
{
  // 1. Over the limit: Burst starts the summary in the background.
  const t = allTurns(141)
  scenes.started = { d: doc(t, { top: [STARTED] }), b: burst(t[t.length - 1][1], 'summarising', t[t.length - 1][1]) }
}
{
  // 2. The summary is ready and waits for the next prompt.
  const t = allTurns(142)
  const d = doc(t, { top: [PENDING], under: { 142: [STARTED] } })
  d.session.compacting = true
  scenes.pending = { d, b: burst(t[t.length - 1][1], 'warning', t[t.length - 1][1]) }
}
{
  // 3. The next prompt went out with the summary in place of the history.
  const t = allTurns(143)
  scenes.finished = { d: doc(t, { under: { 143: [FINISHED], 142: [STARTED] } }), b: burst(64000, 'compacted', 299000), x: SAVED }
}

// ---- Box/Text as HTML --------------------------------------------------------

const NAMED = { black: '#1d1f2b', red: '#e5534b', green: '#6cc644', yellow: '#e8d44d', blue: '#4f6ef7', magenta: '#d6409f', cyan: '#33c4cf', white: '#e6e6e6', gray: '#8b8fa3' }
const BASE16 = ['#1d1f2b', '#e5534b', '#6cc644', '#e8d44d', '#4f6ef7', '#d6409f', '#33c4cf', '#d7dae0', '#6b7089', '#ff6e67', '#8be36a', '#f5e36b', '#7189ff', '#e86cbb', '#5fdbe4', '#ffffff']

function colour(c) {
  if (!c) return ''
  const m = /^ansi256\((\d+)\)$/.exec(c)
  if (m) {
    const n = Number(m[1])
    if (n < 16) return BASE16[n]
    if (n >= 232) { const v = 8 + (n - 232) * 10; return `rgb(${v},${v},${v})` }
    const i = n - 16, s = [0, 95, 135, 175, 215, 255]
    return `rgb(${s[Math.floor(i / 36)]},${s[Math.floor(i / 6) % 6]},${s[i % 6]})`
  }
  return NAMED[c] || c
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
const kids = (children) => (Array.isArray(children) ? children : [children]).filter((x) => x !== '' && x != null).map((x) => (typeof x === 'string' ? esc(x) : x.html)).join('')

function Text(p) {
  const st = []
  if (p.color) st.push('color:' + colour(p.color))
  if (p.backgroundColor) st.push('background:' + colour(p.backgroundColor))
  if (p.bold) st.push('font-weight:700')
  if (p.dimColor) st.push('opacity:.62')
  if (p.wrap === 'wrap') st.push('white-space:pre-wrap;min-width:0')
  else if (p.wrap) st.push('overflow:hidden')
  return { html: `<span style="${st.join(';')}">${kids(p.children)}</span>` }
}

function Box(p) {
  const st = ['display:flex', 'flex-direction:' + (p.flexDirection || 'row')]
  if (p.justifyContent) st.push('justify-content:' + p.justifyContent)
  if (p.columnGap) st.push(`column-gap:${p.columnGap}ch`)
  if (p.marginTop) st.push(`margin-top:${p.marginTop}lh`)
  if (p.flexWrap) st.push('flex-wrap:' + p.flexWrap)
  const cls = p.borderStyle ? ` class="card" data-card="${p.key || ''}"` : ''
  return { html: `<div${cls} style="${st.join(';')}">${kids(p.children)}</div>` }
}

// Claude Code draws a button as its label in square brackets.
const button = Text({ bold: true, children: ['[ Open Claude Burst dashboard ↗ ]'] })
// The mod's own first row, drawn by its Pane hook over what panel() returns.
const full = Text({ bold: true, children: ['[ Full Async Compaction ]'] })
const hide = Box({ flexDirection: 'row', justifyContent: 'flex-end', children: [Text({ bold: true, children: ['[ Hide ]'] })] })

function page(scene) {
  const rows = panel(Box, Text, scene.d, WIDTH, NOW, '', null, scene.b ? [button] : [], scene.b, scene.b ? LIMITS : null, scene.x || null, full)
  return `<!doctype html><meta charset="utf-8"><style>
  html, body { margin: 0; background: #1f2029; }
  #pane { display: inline-block; padding: 14px 18px 18px; background: #1f2029; color: #d7dae0;
    font: 15px/16px Menlo, 'SF Mono', monospace; font-variant-ligatures: none; }
  #title { display: flex; justify-content: space-between; opacity: .62; margin-bottom: .35lh; }
  #hide { width: ${WIDTH}ch; }
  #body { width: ${WIDTH}ch; display: flex; flex-direction: column; }
  #body > div:first-child { margin-bottom: .5lh; }
  span { white-space: pre; }
  .card { box-sizing: border-box; width: ${WIDTH}ch; margin: .5lh 0; padding: .3lh calc(2ch - 3px);
    border: 1px solid #4a4d5e; border-radius: 6px; }
  </style><div id="pane"><div id="title"><span>Usage</span><span>×</span></div><div id="hide">${hide.html}</div><div id="body">${rows.map((r) => r.html).join('')}</div></div>`
}

// ---- photographs -------------------------------------------------------------

const browser = await chromium.launch()
const ctx = await browser.newContext({ deviceScaleFactor: 2, viewport: { width: 700, height: 900 } })
const tab = await ctx.newPage()
const PAD = 12

async function show(name) {
  await tab.setContent(page(scenes[name]))
  const pane = await tab.locator('#pane').boundingBox()
  const cards = {}
  for (const el of await tab.locator('.card').all()) cards[await el.getAttribute('data-card')] = await el.boundingBox()
  return { pane, cards }
}

async function clip(file, pane, top, bottom) {
  await tab.screenshot({ path: join(here, file), fullPage: true, clip: { x: pane.x, y: top, width: pane.width, height: bottom - top } })
  console.log(file)
}

// One card, with a margin of the pane's background round it.
const card = (file, pane, box) => clip(file, pane, box.y - PAD, box.y + box.height + PAD)

{
  const { pane, cards } = await show('steady')
  await clip('usage-sidebar.png', pane, pane.y, pane.y + pane.height)
  // The sidebar scrolls: what a new session shows, then what is under it.
  await clip('sidebar-top.png', pane, pane.y, cards.today.y - PAD / 2)
  await clip('sidebar-scrolled.png', pane, cards.today.y - PAD, pane.y + pane.height)
  for (const id of ['session', 'turns', 'plan', 'savings', 'today', 'sessions', 'days', 'projects']) await card(`card-${id}.png`, pane, cards[id])
}
{
  const { pane, cards } = await show('problem')
  await card('card-mac.png', pane, cards.mac)
}
{
  const { pane, cards } = await show('alone')
  await card('card-session-no-burst.png', pane, cards.session)
}
{
  const { pane, cards } = await show('intelligent')
  await clip('card-session-intelligent.png', pane, pane.y, cards.session.y + cards.session.height + PAD)
}
{
  const { pane, cards } = await show('held')
  await card('card-session-held.png', pane, cards.session)
}
{
  const { pane, cards } = await show('replayed')
  await card('card-turns-replayed.png', pane, cards.turns)
}
for (const [i, name] of ['started', 'pending', 'finished'].entries()) {
  const { pane, cards } = await show(name)
  await clip(`compaction-${i + 1}-${name}.png`, pane, pane.y, cards.turns.y + cards.turns.height + PAD)
}

// The warning as a plan limit gets close. Claude Code draws a toast itself:
// the mod's name, dim, over the text, in a rounded frame. This copies that.
{
  await tab.setContent(`<!doctype html><meta charset="utf-8"><style>
  html, body { margin: 0; background: #1f2029; }
  #pane { display: inline-block; padding: 18px; background: #1f2029; color: #d7dae0;
    font: 15px/20px Menlo, 'SF Mono', monospace; font-variant-ligatures: none; }
  #toast { width: 38ch; padding: .5lh 2ch; border: 1px solid #6b6e80; border-radius: 6px; }
  #toast div:first-child { opacity: .55; }
  </style><div id="pane"><div id="toast"><div>usage-panel</div><div>🟡 Plan limit: 82% of the 5h limit used, resets 16:17 (1h58m)</div></div></div>`)
  const pane = await tab.locator('#pane').boundingBox()
  await clip('toast-limit.png', pane, pane.y, pane.y + pane.height)
}

// The sidebar hidden. Claude Code draws all of this itself: the band above
// the prompt with the mod's button in it (and its own [-], which folds the
// band to one line), the prompt, and the hint line under it, where the mod
// adds its words dim at the end. This copies that.
{
  const line = (inner) => `<div class="row">${inner}</div>`
  const foot = `${line('<span class="rule"></span><span class="dim"> my-app ─</span>')}${line('<span>❯ </span><span class="caret"> </span>')}${line('<span class="rule"></span>')}
    ${line('<span class="red">⏵⏵ bypass permissions on</span><span class="dim"> (shift+tab to cycle) · ← for agents · /show-cost-panel for the usage sidebar</span>')}`
  await tab.setContent(`<!doctype html><meta charset="utf-8"><style>
  html, body { margin: 0; background: #1f2029; }
  #pane { display: inline-block; padding: 16px 18px; background: #1f2029; color: #d7dae0;
    font: 15px/20px Menlo, 'SF Mono', monospace; font-variant-ligatures: none; }
  .shot { width: 100ch; }
  .shot + .shot { margin-top: 1.4lh; }
  .row { display: flex; white-space: pre; }
  .rule { flex: 1; border-top: 1px solid #4a4d5e; margin-top: .5lh; }
  .dim { opacity: .62; } .red { color: #e5534b; } .b { font-weight: 700; }
  .caret { background: #4f6ef7; }
  .cap { opacity: .62; margin-bottom: .4lh; font-style: italic; }
  .end { margin-left: auto; }
  </style><div id="pane">
  <div class="shot"><div class="cap">The band above the prompt, open</div>${line('<span class="b">[ Show usage sidebar ]</span><span class="dim end">[-]</span>')}${foot}</div>
  <div class="shot"><div class="cap">The band folded away</div>${line('<span class="dim">▸ plugin panel hidden · ctrl+x ctrl+a or click to show</span>')}${foot}</div>
  </div>`)
  const pane = await tab.locator('#pane').boundingBox()
  await clip('sidebar-hidden.png', pane, pane.y, pane.y + pane.height)
}

await browser.close()
rmSync(tmp, { recursive: true, force: true })
