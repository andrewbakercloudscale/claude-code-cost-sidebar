// The usage panel in a sidebar inside Claude Code.
//
// The numbers are the panel's own: ccusage-panel.sh runs headless for this
// session (started by ccusage-panel-mod-start) and writes everything it would
// have drawn in its Ghostty split, as numbers, to
// ~/.cache/ccusage-panel-cache/mod/<session id>.json. This mod reads that file
// and draws it: the same figures and traffic lights, plus graphs and insights.
// Nothing is computed twice and no keystrokes are typed anywhere.
//
// /usage-panel opens or focuses the sidebar; /usage-panel pin opens it in
// every new session (the default), /usage-panel unpin stops that. (/usage
// itself is Claude Code's own.)

const PANE = 'usage'
const COMMAND = 'usage-panel'
const COLUMNS = 58 // the sidebar's width to start with; dragging it wins
const READ_MS = 5000 // the panel writes every 10s; reading at 5s halves the lag
const FEED_MS = 30000 // keeps the headless panel alive; it stops after 90s without
const STALE_S = 180 // older than this, the feed has stopped
const PIN_KEY = 'pinned'

let sid = ''
let home = ''
let cwd = ''
let data = null // the panel's last mod/<sid>.json
let raw = ''
let feedError = ''
let pinned = true

export function register(on) {
  on('session.start', async ($, e, next) => {
    sid = await $.session.id()
    home = (await $.env.get('HOME')) || ''
    cwd = (e && e.cwd) || (await $.session.cwd()) || home
    try {
      const v = await $.store.get(PIN_KEY)
      if (v === false) pinned = false
    } catch (err) {
      // No stored choice yet: pinned.
    }
    await feed($)
    await read($)
    $.clock.every(FEED_MS, async () => { await feed($) })
    $.clock.every(READ_MS, async () => {
      if (await read($)) $.ui.invalidate('ui.render')
    })
    try {
      await $.command.register({ name: COMMAND, description: 'The usage panel sidebar: open it, or "pin" / "unpin" it for every new session', immediate: true })
    } catch (err) {
      $.ui.log('could not add /' + COMMAND + ': ' + err)
    }
    if (pinned) {
      try {
        await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS })
      } catch (err) {
        $.ui.log('could not open the usage sidebar: ' + err)
      }
    }
    return next(e)
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = String((e && e.args) || '').trim().toLowerCase()
    if (arg === 'pin' || arg === 'unpin') {
      pinned = arg === 'pin'
      try { await $.store.set(PIN_KEY, pinned) } catch (err) { $.ui.log('could not save the pin: ' + err) }
      $.ui.toast(pinned ? 'Usage panel opens in every new session' : 'Usage panel opens only with /' + COMMAND)
      if (pinned) await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS })
      return {}
    }
    await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS, focus: true, closeOnEscape: true })
    return {}
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const width = Math.max(30, Math.min(100, (e.props && e.props.bodyColumns) || (e.viewport && e.viewport.columns) || 50))
    const now = Math.floor((await $.clock.now()) / 1000)
    return Box({ flexDirection: 'column', children: panel(Box, Text, data, width, now, feedError) })
  })
}

// Starts the headless panel when it is not running, and says this session
// still wants it.
async function feed($) {
  if (!sid || !home) return
  try {
    const r = await $.process.run([home + '/.local/bin/ccusage-panel-mod-start', sid, cwd], { timeoutMs: 10000 })
    feedError = r.exitCode === 0 ? '' : String(r.stderr || 'ccusage-panel-mod-start exited ' + r.exitCode).trim()
  } catch (err) {
    feedError = 'ccusage-panel-mod-start: ' + err
  }
}

// True when the file changed.
async function read($) {
  if (!sid || !home) return false
  let text = ''
  try {
    text = await $.fs.read(home + '/.cache/ccusage-panel-cache/mod/' + sid + '.json')
  } catch (err) {
    return false
  }
  if (text === raw) return false
  raw = text
  try {
    data = JSON.parse(text)
  } catch (err) {
    return false
  }
  return true
}

// ---- the sidebar -------------------------------------------------------------

const TIER = { green: 'green', yellow: 'yellow', red: 'red', purple: 'magenta', cyan: 'cyan' }
const ACCENT = 'cyan'
const BLOCKS = ' ▁▂▃▄▅▆▇█'

export function panel(Box, Text, d, width, now, feedError) {
  const T = (children, props = {}) => Text({ ...props, children: Array.isArray(children) ? children : [children] })
  const rows = []
  if (!d) {
    rows.push(T('Usage', { bold: true, color: ACCENT }))
    rows.push(T('Starting the usage panel for this session…', { dimColor: true }))
    rows.push(T('The first figures take up to a minute: ccusage reads every transcript once.', { dimColor: true, wrap: 'wrap' }))
    if (feedError) rows.push(T(feedError, { color: 'red', wrap: 'wrap' }))
    return rows
  }
  const W = width
  const age = Math.max(0, now - (d.at || now))
  const stale = age > STALE_S

  // Header
  rows.push(Box({
    flexDirection: 'row', justifyContent: 'space-between', children: [
      T('◆ Usage', { bold: true, color: ACCENT }),
      T(stale ? 'stopped ' + ago(age) : 'live · ' + clock(d.at), { color: stale ? 'red' : undefined, dimColor: !stale }),
    ],
  }))
  if (feedError) rows.push(T(feedError, { color: 'red', wrap: 'wrap' }))

  rows.push(...sessionSection(Box, T, d, W))
  rows.push(...todaySection(Box, T, d, W, now))
  rows.push(...daysSection(Box, T, d, W))
  rows.push(...projectsSection(Box, T, d, W))
  rows.push(...topSection(Box, T, d, W))
  const tips = insights(d, now)
  if (tips.length > 0) {
    rows.push(heading(T, 'Insights'))
    for (const t of tips) {
      rows.push(Box({ flexDirection: 'row', children: [T((t.icon || '•') + ' ', { color: TIER[t.tier] || ACCENT }), T(t.text, { wrap: 'wrap' })] }))
    }
  }
  rows.push(...turnsTable(T, d))
  rows.push(...footer(Box, T, d))
  return rows
}

function heading(T, title, note) {
  return T([T(' ', {}), T(title, { bold: true, color: ACCENT }), note ? T('  ' + note, { dimColor: true }) : ''], { wrap: 'truncate-end' })
}

// ---- this session

function sessionSection(Box, T, d, W) {
  const s = d.session || {}
  const out = [heading(T, 'This session', d.sid ? '*' + d.sid.slice(-5) : '')]
  if (!s.model && s.cost == null && !(s.ctx > 0)) {
    out.push(T('No reply yet: the figures start with the first one.', { dimColor: true, wrap: 'wrap' }))
    return out
  }
  out.push(T([
    T(s.model || 'model unknown', { color: TIER[s.model_tier], bold: true }),
    s.folder ? T('  ' + s.folder, { dimColor: true }) : '',
    s.folder_spend != null ? T(' ' + money(s.folder_spend), { dimColor: true }) : '',
  ], { wrap: 'truncate-end' }))
  const turns = (d.turns && d.turns.turns) || []
  const n = turns.length > 0 ? turns[turns.length - 1][0] : 0
  out.push(T([
    T(s.cost == null ? '--' : money(s.cost, 2), { bold: true, color: TIER[s.tier] }),
    T('  '),
    T(s.rate == null ? '' : money(s.rate, 2) + '/hr', { color: TIER[s.rate_tier] }),
    T(n ? '  ' + n + (n === 1 ? ' turn' : ' turns') : '', { dimColor: true }),
    s.avg_session > 0 && s.cost != null && s.cost >= s.avg_session * 0.5 ? T('  ' + ratio(s.cost / s.avg_session) + ' avg', { dimColor: true }) : '',
  ], { wrap: 'truncate-end' }))

  // Context gauge, with the panel's colour thresholds as ticks.
  if (s.ctx > 0 && s.win > 0) {
    const th = d.thresholds || {}
    const pct = (s.ctx * 100) / s.win
    const label = k(s.ctx) + '/' + k(s.win) + ' ' + Math.round(pct) + '%'
    const barW = Math.max(6, W - 6 - label.length)
    const ticks = [th.ctx_yellow, th.ctx_red, th.ctx_purple].filter((x) => x > 0)
    if (s.restart_tokens > 0) ticks.push((s.restart_tokens * 100) / s.win)
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T('ctx', { dimColor: true }),
        gauge(T, pct, barW, TIER[s.ctx_tier] || 'green', ticks),
        T(label, { color: TIER[s.ctx_tier] }),
      ],
    }))
    if (s.compacting) out.push(T('  ⟳ a summary is ready: the next prompt compacts', { color: 'cyan' }))
  }

  // Context per turn, with compactions marked; cost per turn underneath.
  if (turns.length >= 3) {
    const cols = Math.max(10, W - 9)
    const shown = turns.slice(-cols)
    const ctxs = shown.map((t) => t[1])
    const drops = new Set()
    for (let i = 1; i < shown.length; i++) if (shown[i][1] < shown[i - 1][1] * 0.6) drops.add(i)
    const th = d.thresholds || {}
    const win = s.win || 0
    const ctxColour = (v) => {
      if (!win) return 'blue'
      const p = (v * 100) / win
      return p > th.ctx_purple ? 'magenta' : p > th.ctx_red ? 'red' : p > th.ctx_yellow ? 'yellow' : 'blue'
    }
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T('context', { dimColor: true }),
        spark(T, ctxs, (v, i) => (drops.has(i) ? 'cyan' : ctxColour(v)), 0),
      ],
    }))
    const costs = shown.map((t) => (t[4] == null ? 0 : t[4]))
    const med = median(costs.filter((c) => c > 0))
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T('$/turn ', { dimColor: true }),
        spark(T, costs, (v) => (med > 0 && v > med * 4 ? 'red' : med > 0 && v > med * 2 ? 'yellow' : 'green'), 0),
      ],
    }))
    const cache = turns.slice(-20).filter((t) => !t[6]).map((t) => t[3])
    if (cache.length > 0) {
      const avg = cache.reduce((a, b) => a + b, 0) / cache.length
      const label = Math.round(avg) + '% hit'
      out.push(Box({
        flexDirection: 'row', columnGap: 1, children: [
          T('cache  ', { dimColor: true }),
          gauge(T, avg, Math.max(6, W - 10 - label.length), avg >= 90 ? 'green' : avg >= 75 ? 'yellow' : 'red', []),
          T(label, { dimColor: true }),
        ],
      }))
    }
  }
  return out
}

// ---- today

function todaySection(Box, T, d, W, now) {
  const t = d.today || {}
  const b = d.block || {}
  const out = [heading(T, 'Today')]
  if (t.unpriced && !(t.cost > 0)) {
    out.push(T('? an unpriced model ran today: ' + t.unpriced, { color: 'yellow', wrap: 'wrap' }))
  } else {
    out.push(T([
      T(money(t.cost, 2), { bold: true, color: TIER[t.tier] }),
      T(' spent', { dimColor: true }),
      t.pred != null ? T('   by end of day ', { dimColor: true }) : '',
      t.pred != null ? T(money(t.pred, 2), { color: TIER[t.pred_tier] }) : '',
    ], { wrap: 'truncate-end' }))
  }
  // A typical day by hour (30-day average), this hour highlighted.
  if (Array.isArray(d.hourly_avg) && d.hourly_avg.some((v) => v > 0)) {
    const hour = new Date(now * 1000).getHours()
    const cw = Math.max(24, W - 2)
    const hours = stretch(24, cw)
    const vals = hours.map((h) => d.hourly_avg[h])
    const chart = bars(T, Box, vals, 3, (v, i) => (hours[i] === hour ? 'cyan' : hours[i] < hour ? 'blue' : 'gray'))
    out.push(T('a typical day by hour, 30-day average; now in cyan', { dimColor: true, wrap: 'truncate-end' }))
    out.push(...chart)
    out.push(T(axis(['0h', '6h', '12h', '18h', '23h'], cw), { dimColor: true }))
  }
  if (b.active) {
    const left = b.rem || 0
    const used = Math.max(0, Math.min(1, 1 - left / 300))
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T('5h block', { dimColor: true }),
        gauge(T, used * 100, Math.max(6, W - 11 - hm(left).length - 5), 'blue', []),
        T(hm(left) + ' left', { dimColor: true }),
      ],
    }))
    out.push(T([
      T('         ' + money(b.cost), { color: TIER[b.tier] }),
      T(' so far, all sessions ', { dimColor: true }),
      T(money(b.cph, 2) + '/hr ' + (b.label || '').toLowerCase(), { color: TIER[b.tier] }),
    ], { wrap: 'truncate-end' }))
  }
  return out
}

// ---- the last 30 days

function daysSection(Box, T, d, W) {
  const days = d.daily || []
  const p = d.days30 || {}
  if (days.length === 0) return []
  const out = [heading(T, 'Last 30 days')]
  const trend = p.prev > 0 ? p.spend / p.prev : 0
  out.push(T([
    T(money(p.spend), { bold: true, color: TIER[p.tier] }),
    T('  avg ', { dimColor: true }),
    T(money(p.avg) + '/day', { color: TIER[p.avg_tier] }),
    trend > 0 ? T('  ' + (trend >= 1 ? '▲ ' : '▼ ') + ratio(trend) + ' prior 30', { color: trend >= 1.5 ? 'yellow' : trend < 1 ? 'green' : undefined }) : '',
  ], { wrap: 'truncate-end' }))
  const cw = Math.max(days.length, W - 2)
  const idx = stretch(days.length, cw)
  const vals = idx.map((i) => days[i].cost)
  const avg = p.avg || 0
  const th = d.thresholds || {}
  const last = days.length - 1
  out.push(...bars(T, Box, vals, 4, (v, i) => {
    if (idx[i] === last) return 'cyan'
    if (avg > 0 && v > avg * (th.tier_red_mult || 2)) return 'red'
    if (avg > 0 && v > avg * (th.tier_yellow_mult || 1.5)) return 'yellow'
    return 'green'
  }))
  out.push(T(axis([short(days[0].d), short(days[Math.floor(last / 2)].d), 'today'], cw), { dimColor: true }))
  const peak = days.reduce((a, b) => (b.cost > a.cost ? b : a), days[0])
  out.push(T([T('peak ', { dimColor: true }), T(money(peak.cost) + ' on ' + short(peak.d)), T('   week ', { dimColor: true }), T(money(d.week)), T('  month ', { dimColor: true }), T(money(d.month))], { wrap: 'truncate-end' }))

  // Models: one stacked bar, with a legend.
  const models = {}
  for (const x of days) for (const [m, c] of Object.entries(x.models || {})) models[m] = (models[m] || 0) + c
  const ranked = Object.entries(models).filter(([, c]) => c > 0).sort((a, b) => b[1] - a[1])
  const total = ranked.reduce((a, [, c]) => a + c, 0)
  if (total > 0 && ranked.length > 0) {
    const palette = ['magenta', 'blue', 'yellow', 'green', 'cyan']
    const barW = Math.max(10, W - 2)
    const cells = []
    let used = 0
    ranked.forEach(([, c], i) => {
      const n = i === ranked.length - 1 ? barW - used : Math.round((c * barW) / total)
      if (n > 0) cells.push(T('█'.repeat(n), { color: palette[i % palette.length] }))
      used += Math.max(0, n)
    })
    out.push(Box({ flexDirection: 'row', children: cells }))
    out.push(Box({
      flexDirection: 'row', flexWrap: 'wrap', columnGap: 2, children: ranked.slice(0, 5).map(([m, c], i) =>
        T([T('■ ', { color: palette[i % palette.length] }), T(modelName(m) + ' ' + Math.round((c * 100) / total) + '%', { dimColor: true })])),
    }))
  }
  return out
}

// ---- projects and sessions

function projectsSection(Box, T, d, W) {
  const ps = d.projects || []
  if (ps.length === 0) return []
  const out = [heading(T, 'By project', '30 days')]
  const max = ps[0].cost || 1
  const nameW = Math.min(22, Math.max(...ps.map((p) => p.name.length)))
  const here = (d.session && d.session.folder) || ''
  for (const p of ps) {
    const barW = Math.max(4, W - nameW - 12)
    const n = Math.max(1, Math.round((p.cost / max) * barW))
    const mine = p.name === here
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T(pad(cut(p.name, nameW), nameW), { bold: mine, color: mine ? ACCENT : undefined }),
        T('█'.repeat(n) + ' '.repeat(barW - n), { color: mine ? ACCENT : 'blue' }),
        T(lpad(money(p.cost), 7)),
      ],
    }))
  }
  return out
}

function topSection(Box, T, d, W) {
  const top = d.top || []
  if (top.length === 0) return []
  const out = [heading(T, 'Top sessions today')]
  const max = top[0].cost || 1
  for (const r of top) {
    const mine = r.sid === d.sid
    const barW = Math.max(4, W - 30)
    const n = Math.max(1, Math.round((r.cost / max) * barW))
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T('*' + r.sid.slice(-5), { bold: mine, color: mine ? ACCENT : undefined }),
        T(lpad(money(r.cost), 6), { bold: mine }),
        T('█'.repeat(n) + ' '.repeat(barW - n), { color: mine ? ACCENT : 'blue' }),
        T(clock(Date.parse(r.last) / 1000) + (mine ? ' ◀' : ''), { dimColor: !mine, color: mine ? ACCENT : undefined }),
      ],
    }))
  }
  return out
}

// ---- insights: a few plain sentences, only when there is something to say

export function insights(d, now) {
  const out = []
  const s = d.session || {}
  const t = d.today || {}
  const b = d.block || {}
  const turns = (d.turns && d.turns.turns) || []
  const recent = turns.slice(-20).filter((x) => !x[6])

  if (s.restart_tokens > 0 && s.ctx >= s.restart_tokens) {
    out.push({ tier: 'red', icon: '!', text: 'Context is ' + k(s.ctx) + ', past the ' + k(s.restart_tokens) + ' restart line: every turn re-reads all of it. /compact or restart.' })
  } else if (recent.length >= 5 && s.ctx > 0) {
    const grow = (recent[recent.length - 1][1] - recent[0][1]) / (recent.length - 1)
    if (grow > 500 && s.restart_tokens > 0) {
      const left = Math.round((s.restart_tokens - s.ctx) / grow)
      out.push({ tier: left < 30 ? 'yellow' : 'cyan', icon: '↗', text: 'Context grows about ' + k(grow) + ' a turn: the ' + k(s.restart_tokens) + ' restart line in about ' + left + ' turns.' })
    }
  }

  if (recent.length >= 5) {
    const hit = recent.reduce((a, x) => a + x[3], 0) / recent.length
    const costs = recent.map((x) => x[4]).filter((c) => c != null)
    if (hit < 85) {
      out.push({ tier: 'yellow', icon: '◇', text: 'Cache hit is ' + Math.round(hit) + '% over the last 20 turns: writes cost about 25 times a read, so a pause over 5 minutes or a changed prefix costs more.' })
    } else if (costs.length > 0) {
      out.push({ tier: 'green', icon: '◇', text: 'Cache hit ' + Math.round(hit) + '%: a turn costs ' + money(median(costs), 2) + ' (median, last 20).' })
    }
    const all = turns.slice(-50).filter((x) => x[4] != null)
    const med = median(all.map((x) => x[4]))
    const worst = all.reduce((a, x) => (a == null || x[4] > a[4] ? x : a), null)
    if (worst && med > 0 && worst[4] > med * 4 && worst[4] >= 0.05) {
      out.push({ tier: 'yellow', icon: '▲', text: 'Turn ' + worst[0] + ' cost ' + money(worst[4], 2) + ', ' + Math.round(worst[4] / med) + '× the median: it added ' + k(worst[2]) + ' of context.' })
    }
  }

  if (s.cost != null && s.avg_session > 0 && s.cost > s.avg_session * 3) {
    out.push({ tier: s.tier || 'yellow', icon: '$', text: 'This session has cost ' + ratio(s.cost / s.avg_session) + ' your 7-day average session (' + money(s.avg_session, 2) + ').' })
  }

  if (t.cost != null && t.typical_so_far > 1) {
    const pace = t.cost / t.typical_so_far
    if (pace >= 1.5) out.push({ tier: pace >= 2 ? 'red' : 'yellow', icon: '◔', text: 'A busy day: ' + ratio(pace) + ' a typical day\'s spend by this hour.' })
    else if (pace <= 0.5) out.push({ tier: 'green', icon: '◔', text: 'A quiet day: ' + Math.round(pace * 100) + '% of a typical day\'s spend by this hour.' })
  }

  if (b.active && (b.tier === 'red' || b.tier === 'yellow')) {
    out.push({ tier: b.tier, icon: '≋', text: 'All sessions together are burning ' + money(b.cph, 2) + '/hr (' + (b.label || '').toLowerCase() + '); the 5h block resets in ' + hm(b.rem) + '.' })
  }

  const ps = d.projects || []
  const ptotal = ps.reduce((a, p) => a + p.cost, 0)
  if (ps.length > 1 && ptotal > 0 && ps[0].cost / ptotal >= 0.3) {
    out.push({ tier: 'cyan', icon: '▣', text: ps[0].name + ' is ' + Math.round((ps[0].cost * 100) / ptotal) + '% of the last 30 days across your top projects.' })
  }

  if (Array.isArray(d.hourly_avg)) {
    let best = 0
    d.hourly_avg.forEach((v, h) => { if (v > d.hourly_avg[best]) best = h })
    if (d.hourly_avg[best] > 0) out.push({ tier: 'cyan', icon: '◷', text: 'Your busiest hour is usually ' + String(best).padStart(2, '0') + ':00, about ' + money(d.hourly_avg[best]) + ' an hour.' })
  }
  return out.slice(0, 6)
}

// ---- the panel's own turn table and footer rows, colours kept

function turnsTable(T, d) {
  const lines = parseAnsi(d.table || '')
  if (lines.length === 0) return []
  const out = [heading(T, 'Recent turns')]
  for (const line of lines.slice(0, 9)) out.push(lineText(T, line))
  return out
}

function footer(Box, T, d) {
  const out = []
  const lines = parseAnsi(d.summary || '')
  const keep = lines.filter((l) => /Proxy State:|License:|no price for/.test(l.text))
  if (keep.length > 0) out.push(T(' '))
  for (const l of keep) out.push(lineText(T, l))
  for (const e of d.errors || []) out.push(T('! ' + e, { color: 'red', wrap: 'truncate-end' }))
  return out
}

// ---- drawing helpers

// A horizontal gauge: pct filled in colour, the rest dim, ticks at the given
// percentages.
export function gauge(T, pct, width, colour, ticks) {
  const fill = Math.max(0, Math.min(width, Math.round((pct / 100) * width)))
  const marks = new Set((ticks || []).map((p) => Math.round((p / 100) * width)).filter((i) => i > 0 && i < width))
  const segs = []
  let cur = null
  const push = (ch, props) => {
    const key = JSON.stringify(props)
    if (cur && cur.key === key) cur.text += ch
    else { cur = { key, text: ch, props }; segs.push(cur) }
  }
  for (let i = 0; i < width; i++) {
    if (i < fill) push('█', { color: colour })
    else if (marks.has(i)) push('│', { dimColor: true })
    else push('░', { dimColor: true })
  }
  return T(segs.map((g) => T(g.text, g.props)))
}

// A one-row sparkline, each cell coloured by colourOf(value, index).
export function spark(T, vals, colourOf, floor) {
  const max = Math.max(...vals, 0)
  const min = floor == null ? Math.min(...vals) : floor
  const span = max - min || 1
  const segs = []
  vals.forEach((v, i) => {
    const level = v <= 0 ? 0 : Math.max(1, Math.round(((v - min) / span) * 8))
    const ch = BLOCKS[level]
    const c = colourOf(v, i)
    const last = segs[segs.length - 1]
    if (last && last.c === c) last.t += ch
    else segs.push({ c, t: ch })
  })
  return T(segs.map((g) => T(g.t, { color: g.c })))
}

// A bar chart `height` rows tall, in eighths, each column coloured.
export function bars(T, Box, vals, height, colourOf) {
  const max = Math.max(...vals, 0) || 1
  const rows = []
  for (let r = height - 1; r >= 0; r--) {
    const segs = []
    vals.forEach((v, i) => {
      const eighths = Math.round((v / max) * height * 8)
      const inRow = Math.max(0, Math.min(8, eighths - r * 8))
      const ch = inRow === 0 ? (r === 0 && v > 0 ? '▁' : ' ') : BLOCKS[inRow]
      const c = colourOf(v, i)
      const last = segs[segs.length - 1]
      if (last && last.c === c) last.t += ch
      else segs.push({ c, t: ch })
    })
    rows.push(T(segs.map((g) => T(g.t, { color: g.c }))))
  }
  return rows
}

// Which of n items each of `width` columns shows, so a chart fills the pane:
// every item gets the same number of columns, give or take one.
export function stretch(n, width) {
  const out = []
  for (let c = 0; c < width; c++) out.push(Math.min(n - 1, Math.floor((c * n) / width)))
  return out
}

// Labels spread under a chart `width` columns wide: first at the left, last
// at the right, the rest evenly between.
export function axis(labels, width) {
  const out = new Array(width).fill(' ')
  labels.forEach((l, i) => {
    let at = labels.length === 1 ? 0 : Math.round((i * (width - 1)) / (labels.length - 1))
    if (i === labels.length - 1) at = width - l.length
    else if (i > 0) at = Math.max(0, at - Math.floor(l.length / 2))
    for (let j = 0; j < l.length && at + j < width; j++) if (at + j >= 0) out[at + j] = l[j]
  })
  return out.join('')
}

// ---- formatting

export function money(v, places) {
  if (v == null || isNaN(v)) return '--'
  const p = places != null ? places : Math.abs(v) >= 100 ? 0 : Math.abs(v) >= 10 ? 1 : 2
  const s = Math.abs(v).toFixed(p).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return (v < 0 ? '-$' : '$') + s
}

export function k(n) {
  if (n == null || isNaN(n)) return '--'
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 2).replace(/\.?0+$/, '') + 'M'
  if (n >= 1e3) return Math.round(n / 1e3) + 'k'
  return String(Math.round(n))
}

function ratio(r) {
  return r >= 10 ? Math.round(r) + '×' : r.toFixed(1) + '×'
}

function hm(mins) {
  const m = Math.max(0, Math.round(mins || 0))
  return Math.floor(m / 60) + 'h' + String(m % 60).padStart(2, '0') + 'm'
}

function clock(epoch) {
  if (!epoch || isNaN(epoch)) return '--:--'
  const t = new Date(epoch * 1000)
  return String(t.getHours()).padStart(2, '0') + ':' + String(t.getMinutes()).padStart(2, '0')
}

function ago(s) {
  return s < 120 ? s + 's ago' : s < 7200 ? Math.round(s / 60) + 'm ago' : Math.round(s / 3600) + 'h ago'
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
function short(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || '')
  return m ? Number(m[3]) + ' ' + MONTHS[Number(m[2]) - 1] : iso || ''
}

export function modelName(id) {
  const m = /claude-([a-z]+)-(\d+)(?:-(\d+))?/.exec(id || '')
  if (!m) return id || '?'
  return m[1][0].toUpperCase() + m[1].slice(1) + ' ' + m[2] + (m[3] && m[3].length <= 2 ? '.' + m[3] : '')
}

function median(xs) {
  if (xs.length === 0) return 0
  const s = [...xs].sort((a, b) => a - b)
  const m = Math.floor(s.length / 2)
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2
}

function pad(s, n) { return s.length >= n ? s : s + ' '.repeat(n - s.length) }
function lpad(s, n) { return s.length >= n ? s : ' '.repeat(n - s.length) + s }
function cut(s, n) { return s.length <= n ? s : '…' + s.slice(-(n - 1)) }

// ---- the panel's ANSI rows, as Text with the panel's own colours

function lineText(T, line) {
  return T(line.segs.map((g) => T(g.text, { color: g.color, backgroundColor: g.bg, bold: g.bold || undefined, dimColor: g.dim || undefined })), { wrap: 'truncate-end' })
}

// 1, 2, 30-37, 90-97, and 38/48 with 5;n or 2;r;g;b. Anything else is
// dropped rather than drawn as escape codes.
export function parseAnsi(raw) {
  const lines = []
  for (const l of String(raw).split('\n')) {
    if (l.trim() === '') continue
    const segs = []
    let st = {}
    const parts = l.split(/\x1b\[([0-9;]*)m/)
    for (let i = 0; i < parts.length; i++) {
      if (i % 2 === 1) st = sgr(st, parts[i])
      else if (parts[i] !== '') segs.push({ text: parts[i].replace(/\x1b\[[0-9;?]*[A-Za-z]/g, ''), color: st.color, bg: st.bg, bold: st.bold, dim: st.dim })
    }
    lines.push({ text: segs.map((g) => g.text).join(''), segs })
  }
  return lines
}

function sgr(st, codes) {
  const c = codes === '' ? [0] : codes.split(';').map(Number)
  let out = { ...st }
  for (let i = 0; i < c.length; i++) {
    const n = c[i]
    if (n === 0) out = {}
    else if (n === 1) out.bold = true
    else if (n === 2) out.dim = true
    else if (n === 22) { out.bold = false; out.dim = false }
    else if (n === 39) out.color = undefined
    else if (n >= 30 && n <= 37) out.color = 'ansi256(' + (n - 30) + ')'
    else if (n >= 90 && n <= 97) out.color = 'ansi256(' + (n - 90 + 8) + ')'
    else if (n === 38 && c[i + 1] === 5) { out.color = 'ansi256(' + c[i + 2] + ')'; i += 2 }
    else if (n === 38 && c[i + 1] === 2) { out.color = 'rgb(' + c[i + 2] + ',' + c[i + 3] + ',' + c[i + 4] + ')'; i += 4 }
    else if (n === 49) out.bg = undefined
    else if (n === 48 && c[i + 1] === 5) { out.bg = 'ansi256(' + c[i + 2] + ')'; i += 2 }
    else if (n === 48 && c[i + 1] === 2) { out.bg = 'rgb(' + c[i + 2] + ',' + c[i + 3] + ',' + c[i + 4] + ')'; i += 4 }
  }
  return out
}
