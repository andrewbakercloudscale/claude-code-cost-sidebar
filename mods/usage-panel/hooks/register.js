// The usage panel in a sidebar inside Claude Code.
//
// The numbers are the panel's own: ccusage-panel.sh runs headless for this
// session (started by ccusage-panel-mod-start) and writes everything it would
// have drawn in its Ghostty split, as numbers, to
// ~/.cache/ccusage-panel-cache/mod/<session id>.json. This mod reads that file
// and draws it: the same figures and traffic lights, plus graphs and insights.
// Nothing is computed twice and no keystrokes are typed anywhere.
//
// With Claude Burst on this Mac (the panel's JSON names its dashboard), the
// session's one ctx bar is Burst's: the context it really sends, by part,
// against its compaction limit. Burst's standing problems sit in This Mac.
//
// Also with Burst: Plan Utilisation, the share of the plan's 5-hour and weekly
// limits used, from the limit headers on Anthropic's replies (Burst keeps the
// latest for about a minute), with a toast when a limit is close.
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
const LIMITS_MS = 15000 // the plan's limits: Burst keeps only its last 20 replies
const EXTRA_MS = 60000 // Burst's slower figures
const LIMITS_KEY = 'limits'
// The context without Claude Burst, as a share of the model's window: green
// under 40%, amber to 70%, red beyond (400k and 700k of a 1M window). Every
// turn re-sends the whole context, so past these it is time to /compact or
// /clear by hand.
const CTX_AMBER = 0.4
const CTX_RED = 0.7
const LIMIT_WARN = 0.8 // a toast when a plan limit passes this, and again at
const LIMIT_ALARM = 0.95
const PIN_KEY = 'pinned'
const LAYOUT_KEY = 'layout'
// The sidebar's sections, most specific first. This Mac (proxy state,
// licence, Burst's standing problems, its dashboard button) is third, under
// the turn table: a problem there must not sit below a screen of charts.
// Plan Utilisation is next: how close the plan's limits are.
export const SECTIONS = ['session', 'turns', 'mac', 'plan', 'today', 'sessions', 'days', 'projects']

let sid = ''
let home = ''
let cwd = ''
let data = null // the panel's last mod/<sid>.json
let raw = ''
let feedError = ''
let pinned = true
let layout = null // { order, hidden } as the person left it
let burst = null // { down, mod }: Burst's /api/mod answer; null without Burst
let burstRaw = ''
let limits = null // [{ key, util, reset }]: the plan's limits, as Anthropic last reported them
let extra = null // { saved, secondary, warn }: Burst's slower figures, and the percent of its limit it warns at
const warned = {} // limit window and reset time -> the level already toasted

// A stored layout made whole: unknown names dropped, sections added since
// it was saved put back in their default place.
export function layoutOf(l) {
  const order = (l && Array.isArray(l.order) ? l.order : []).filter((x) => SECTIONS.includes(x))
  for (const x of SECTIONS) {
    if (order.includes(x)) continue
    const before = SECTIONS.slice(0, SECTIONS.indexOf(x)).reverse().find((y) => order.includes(y))
    order.splice(before ? order.indexOf(before) + 1 : 0, 0, x)
  }
  const hidden = (l && Array.isArray(l.hidden) ? l.hidden : []).filter((x) => SECTIONS.includes(x))
  return { order, hidden: [...new Set(hidden)] }
}

// "/usage-panel hide today", "show", "up", "down", "top", "bottom", "reset":
// the new layout, or a string saying what was wrong.
export function relayout(l, verb, name) {
  const lay = layoutOf(l)
  if (verb === 'reset') return layoutOf(null)
  if (!SECTIONS.includes(name)) return 'Sections: ' + SECTIONS.join(', ')
  const i = lay.order.indexOf(name)
  const move = (j) => { lay.order.splice(i, 1); lay.order.splice(Math.max(0, Math.min(lay.order.length, j)), 0, name) }
  if (verb === 'hide') lay.hidden = [...new Set([...lay.hidden, name])]
  else if (verb === 'show') lay.hidden = lay.hidden.filter((x) => x !== name)
  else if (verb === 'up') move(i - 1)
  else if (verb === 'down') move(i + 1)
  else if (verb === 'top') move(0)
  else if (verb === 'bottom') move(SECTIONS.length)
  return lay
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    sid = await $.session.id()
    home = (await $.env.get('HOME')) || ''
    cwd = (e && e.cwd) || (await $.session.cwd()) || home
    try {
      layout = (await $.store.get(LAYOUT_KEY)) || null
    } catch (err) {
      // No stored layout: the default.
    }
    try {
      const v = await $.store.get(PIN_KEY)
      if (v === false) pinned = false
    } catch (err) {
      // No stored choice yet: pinned.
    }
    await feed($)
    await read($)
    await readBurst($)
    await readLimits($)
    await readExtras($)
    $.clock.every(FEED_MS, async () => { await feed($) })
    $.clock.every(LIMITS_MS, async () => { if (await readLimits($)) $.ui.invalidate('ui.render') })
    $.clock.every(EXTRA_MS, async () => { if (await readExtras($)) $.ui.invalidate('ui.render') })
    $.clock.every(READ_MS, async () => {
      const changed = await read($)
      if ((await readBurst($)) || changed) $.ui.invalidate('ui.render')
    })
    try {
      await $.command.register({ name: COMMAND, description: 'The usage sidebar: open it; pin / unpin; hide, show, up, down, top, bottom <section>; sections; reset', immediate: true })
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
    const [verb, name] = arg.split(/\s+/)
    if (['hide', 'show', 'up', 'down', 'top', 'bottom', 'reset'].includes(verb)) {
      const next = relayout(layout, verb, name)
      if (typeof next === 'string') {
        $.ui.toast(next)
        return {}
      }
      layout = next
      try { await $.store.set(LAYOUT_KEY, layout) } catch (err) { $.ui.log('could not save the layout: ' + err) }
      $.ui.invalidate('ui.render')
      return {}
    }
    if (verb === 'sections') {
      const lay = layoutOf(layout)
      $.ui.toast(lay.order.map((x) => (lay.hidden.includes(x) ? '(' + x + ')' : x)).join(' · '))
      return {}
    }
    await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS, focus: true, closeOnEscape: true })
    return {}
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const width = Math.max(30, Math.min(100, (e.props && e.props.bodyColumns) || (e.viewport && e.viewport.columns) || 50))
    const now = Math.floor((await $.clock.now()) / 1000)
    const extras = []
    // Claude Burst's dashboard, as the pane's [View] was: the dashboard when
    // it answers, else Burst's support console, which is up when it is not.
    const b = data && data.burst
    if (b && b.dashboard) {
      extras.push(Button({
        // Not plain: Claude Code draws it as a button, so it reads as one.
        key: 'burst', label: 'Open Claude Burst dashboard ↗', hotkey: 'v',
        onPress: async () => {
          let url = b.dashboard
          try {
            const r = await $.http.fetch(b.dashboard)
            if (!r.ok && b.console) url = b.console
          } catch (err) {
            if (b.console) url = b.console
          }
          try { await $.process.run(['open', url]) } catch (err) { $.ui.toast('could not open ' + url) }
        },
      }))
    }
    const rows = panel(Box, Text, data, width, now, feedError, layout, extras, burst, limits, extra)
    return Box({ flexDirection: 'column', children: rows })
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

// Burst's own account of this session, from its dashboard. True when what
// the sidebar draws of it changed. Alerts are not asked for (since = now):
// they are the burst-band mod's to show.
async function readBurst($) {
  const b = data && data.burst
  if (!b || !b.dashboard || !sid) {
    const had = burst !== null
    burst = null
    burstRaw = ''
    return had
  }
  let next = { down: true, mod: null }
  try {
    const since = Math.floor((await $.clock.now()) / 1000)
    const r = await $.http.fetch(b.dashboard.replace(/\/+$/, '') + '/api/mod?session=' + encodeURIComponent(sid) + '&since=' + since)
    if (r.ok) {
      const m = JSON.parse(r.text)
      next = { down: false, mod: { route: m.route, overflow: m.overflow, primary_failing: m.primary_failing, session: m.session, problems: m.problems } }
    }
  } catch (err) {
    // Not answering, or not Burst's answer: drawn as down.
  }
  const text = JSON.stringify(next)
  if (text === burstRaw) return false
  burstRaw = text
  burst = next
  return true
}

// The plan's limits: the limit headers on Anthropic's latest reply. Burst
// keeps the headers of its last 20 replies of any kind, heartbeats included,
// so a model reply is in the list for about a minute and less with several
// sessions open. Hence every 15 seconds, and the last reading is kept in the
// store: a session that has not had a reply yet, or missed one, shows the
// reading another session took. True when what the sidebar draws changed.
// A limit that has passed 80% or 95% is toasted, once per level and window.
async function readLimits($) {
  const b = data && data.burst
  if (!b || !b.dashboard || !sid) {
    const had = limits !== null
    limits = null
    return had
  }
  const before = JSON.stringify(limits)
  const now = Math.floor((await $.clock.now()) / 1000)
  let found = null
  try {
    const r = await $.http.fetch(b.dashboard.replace(/\/+$/, '') + '/api/responses')
    if (r.ok) found = limitsOf(JSON.parse(r.text))
  } catch (err) {
    found = null
  }
  if (found) {
    limits = found
    if (JSON.stringify(found) !== before) {
      try { await $.store.set(LIMITS_KEY, found) } catch (err) { $.ui.log('could not save the plan limits: ' + err) }
    }
  } else if (limits === null) {
    try {
      const kept = await $.store.get(LIMITS_KEY)
      if (Array.isArray(kept) && kept.every((l) => l && typeof l.key === 'string' && typeof l.util === 'number')) limits = kept
    } catch (err) {
      limits = null
    }
  }
  for (const l of limits || []) {
    if (!(l.reset > now)) continue
    const level = l.util >= LIMIT_ALARM ? 2 : l.util >= LIMIT_WARN ? 1 : 0
    const key = l.key + ':' + l.reset
    if (level > (warned[key] || 0)) {
      warned[key] = level
      limitToast($, l, now)
    }
  }
  return JSON.stringify(limits) !== before
}

// Burst's slower figures, once a minute: what compaction has saved this
// session, and what went to the secondary today. True when they changed.
async function readExtras($) {
  const b = data && data.burst
  if (!b || !b.dashboard || !sid) {
    const had = extra !== null
    extra = null
    return had
  }
  const base = b.dashboard.replace(/\/+$/, '')
  const get = async (path) => {
    try {
      const r = await $.http.fetch(base + path)
      return r.ok ? JSON.parse(r.text) : null
    } catch (err) {
      return null
    }
  }
  const before = JSON.stringify(extra)
  const now = Math.floor((await $.clock.now()) / 1000)
  const state = await get('/api/state')
  const next = { saved: null, secondary: null, warn: 0 }
  const cfg = state && state.context && state.context.compaction
  if (cfg && cfg.warn_at_percent > 0) next.warn = cfg.warn_at_percent
  const stats = state && state.context && state.context.compaction_stats
  const mine = ((stats && stats.sessions) || []).filter((x) => x && x.session === sid)
  if (mine.length > 0) next.saved = { net: mine.reduce((a, x) => a + (x.net_usd || 0), 0), n: mine.reduce((a, x) => a + (x.compactions || 0), 0) }
  if (state && state.today && state.today.SecondaryRequests > 0) {
    const day = new Date(now * 1000)
    const p2 = (n) => String(n).padStart(2, '0')
    const ymd = day.getFullYear() + '-' + p2(day.getMonth() + 1) + '-' + p2(day.getDate())
    const usage = await get('/api/usage?range=custom&limit=1&from=' + ymd + '&to=' + ymd + 'T23:59')
    const others = ((usage && usage.by_provider) || []).filter((x) => x && x.key !== 'anthropic' && x.requests > 0)
    if (others.length > 0) next.secondary = { requests: others.reduce((a, x) => a + x.requests, 0), usd: others.reduce((a, x) => a + (x.usd || 0), 0), names: others.map((x) => x.key) }
  }
  extra = next.saved || next.secondary || next.warn ? next : null
  return JSON.stringify(extra) !== before
}

// The warning for a limit that is close: longer on screen from 95%.
function limitToast($, l, now) {
  $.ui.toast('Plan limit: ' + Math.round(l.util * 100) + '% of the ' + limitName(l.key) + ' limit used, resets ' + when(l.reset, now), { timeoutMs: l.util >= LIMIT_ALARM ? 30000 : 15000 })
}

// The plan's limits from Burst's list of recent replies: the newest reply
// that carries Anthropic's utilisation headers, one row per window (5h, 7d,
// and any other it names), shortest window first. null when none does.
export function limitsOf(responses) {
  if (!Array.isArray(responses)) return null
  const rows = responses.filter((r) => r && r.headers && typeof r.headers === 'object')
    .sort((a, b) => String(b.time || '').localeCompare(String(a.time || '')))
  for (const r of rows) {
    const out = []
    for (const [name, v] of Object.entries(r.headers)) {
      const m = /^anthropic-ratelimit-unified-(.+)-utilization$/.exec(name)
      if (!m || m[1].startsWith('grace')) continue
      const util = Number(v)
      if (isNaN(util)) continue
      out.push({ key: m[1], util, reset: Number(r.headers['anthropic-ratelimit-unified-' + m[1] + '-reset']) || 0 })
    }
    if (out.length > 0) return out.sort((a, b) => windowSeconds(a.key) - windowSeconds(b.key) || a.key.localeCompare(b.key))
  }
  return null
}

// "5h" is 18000, "7d" and "7d-opus" 604800; 0 when the name says no length.
function windowSeconds(key) {
  const m = /^(\d+)([hd])/.exec(key)
  return m ? Number(m[1]) * (m[2] === 'h' ? 3600 : 86400) : 0
}

// "5h", "weekly", "weekly opus".
function limitName(key) {
  return key.replace(/^7d/, 'weekly').replace(/[-_]+/g, ' ')
}

// A time ahead: "16:00 (1h41m)" today, "Thu 02:00" on another day.
function when(epoch, now) {
  const t = new Date(epoch * 1000)
  const same = t.toDateString() === new Date(now * 1000).toDateString()
  return same ? clock(epoch) + ' (' + hm((epoch - now) / 60) + ')' : DAYS[t.getDay()] + ' ' + clock(epoch)
}
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

// The plan on the panel's License row, and what it costs a month where that
// is a published flat price. null for an API key, or no row.
export function planOf(summary) {
  const line = parseAnsi(summary || '').map((l) => l.text).find((t) => /License:/.test(t))
  if (!line) return null
  const label = line.replace(/^.*License:\s*/, '').trim()
  if (!label || /^API key/.test(label)) return null
  const price = /^Max \(20x\)/.test(label) ? 200 : /^Max \(5x\)/.test(label) ? 100 : /^Pro\b/.test(label) ? 20 : 0
  return { label, price }
}

// ---- the sidebar -------------------------------------------------------------

const TIER = { green: 'green', yellow: 'yellow', red: 'red', purple: 'magenta', cyan: 'cyan' }
const ACCENT = 'cyan'
const BLOCKS = ' ▁▂▃▄▅▆▇█'

export function panel(Box, Text, d, width, now, feedError, layout, extras = [], burst = null, limits = null, extra = null) {
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

  // Most specific first: this session, then today across sessions, then the
  // last 30 days, then this Mac's set-up. Each block's insights sit under it.
  // The order, and which are shown, is the person's (see layoutOf).
  const tips = insights(d, now, limits, extra, burst)
  const notes = (scope) => tips.filter((t) => t.scope === scope).map((t) =>
    Box({ flexDirection: 'row', children: [T((t.icon || '•') + ' ', { color: TIER[t.tier] || ACCENT }), T(t.text, { wrap: 'wrap' })] }))
  // Each section is a card: a rounded border, its heading inside, so where
  // one ends and the next starts is plain. The border and padding take 4.
  const IW = Math.max(26, W - 4)
  const draw = {
    session: () => [...sessionSection(Box, T, d, IW, burst, extra && extra.warn), ...notes('session'), ...notes('burst')],
    mac: () => {
      const foot = [...footer(Box, T, d), ...burstRows(Box, T, burst), ...extras]
      return foot.length > 0 ? [heading(T, 'This Mac'), ...foot] : []
    },
    turns: () => turnsTable(T, d),
    plan: () => {
      const body = planSection(Box, T, d, IW, now, limits)
      return body.length > 0 ? [...body, ...notes('plan')] : []
    },
    today: () => [...todaySection(Box, T, d, IW, now), ...notes('today')],
    sessions: () => topSection(Box, T, d, IW),
    days: () => daysSection(Box, T, d, IW),
    projects: () => [...projectsSection(Box, T, d, IW), ...notes('general')],
  }
  const lay = layoutOf(layout)
  for (const id of lay.order) {
    if (lay.hidden.includes(id)) continue
    const body = draw[id]()
    if (body.length > 0) rows.push(card(Box, id, body))
  }
  if (lay.hidden.length > 0) rows.push(T('Hidden: ' + lay.hidden.join(', ') + ' (/' + 'usage-panel show <name>)', { dimColor: true, wrap: 'wrap' }))
  return rows
}

function card(Box, key, children) {
  return Box({ key, flexDirection: 'column', borderStyle: 'round', borderColor: 'gray', borderDimColor: true, paddingLeft: 1, paddingRight: 1, children })
}

// A card's title, bold, with a short dim note after it.
function heading(T, title, note) {
  return T([T(title, { bold: true, color: ACCENT }), note ? T('  ' + note, { dimColor: true }) : ''], { wrap: 'truncate-end' })
}

// A smaller heading inside a card, for one chart of several.
function sub(T, title, note) {
  return T([T(title, { color: ACCENT }), note ? T('  ' + note, { dimColor: true }) : ''], { wrap: 'truncate-end' })
}

// ---- this session

function sessionSection(Box, T, d, W, burst, warnPct) {
  const s = d.session || {}
  // A long folder loses its start, not its end: the end is what tells two
  // repos apart.
  const id = d.sid ? '*' + d.sid.slice(-5) : ''
  const room = W - 'This session'.length - 2 - (id ? id.length + 3 : 0)
  const out = [heading(T, 'This session', [id, s.folder ? cut(s.folder, Math.max(4, room)) : ''].filter(Boolean).join(' · '))]
  // Before the first reply the panel knows no model ("Unknown") and prices
  // nothing ($0): say so rather than draw that as a reading.
  const turnsSoFar = (d.turns && d.turns.turns) || []
  const sent = burst && !burst.down && burst.mod && burst.mod.session && burst.mod.session.context > 0 ? burst.mod.session : null
  if (turnsSoFar.length === 0 && !(s.ctx > 0) && !sent) {
    out.push(T('No reply yet: the figures start with the first one.', { dimColor: true, wrap: 'wrap' }))
    return out
  }
  const turns = (d.turns && d.turns.turns) || []
  const n = turns.length > 0 ? turns[turns.length - 1][0] : 0
  out.push(T([
    T(s.model || 'model unknown', { color: TIER[s.model_tier], bold: true }),
    T('  '),
    T(s.cost == null ? '--' : money(s.cost, 2), { bold: true, color: TIER[s.tier] }),
    T(s.rate == null ? '' : '  ' + money(s.rate, 2) + '/hr', { color: TIER[s.rate_tier] }),
    T(n ? '  ' + n + (n === 1 ? ' turn' : ' turns') : '', { dimColor: true }),
    s.avg_session > 0 && s.cost != null && s.cost >= s.avg_session * 0.5 ? T('  ' + ratio(s.cost / s.avg_session) + ' avg', { dimColor: true }) : '',
  ], { wrap: 'truncate-end' }))

  // One context bar. With Claude Burst it is Burst's: what is really sent
  // (after Burst's own compaction, which Claude Code's figure does not know
  // about), by part, against the model's window, with Burst's warning and
  // compaction lines marked. Otherwise the
  // panel's gauge against the model's window, its colour thresholds as ticks.
  if (sent) {
    out.push(...sentBar(Box, T, sent, W, s.win || 0, warnPct))
    if (s.compacting) out.push(T('  ⟳ a summary is ready: the next prompt compacts', { color: 'cyan' }))
    else if (sent.state === 'warning') out.push(T('! Close to the limit: Burst compacts at ' + k(sent.compact_at) + '.', { color: 'yellow', wrap: 'wrap' }))
    else if (sent.state && sent.state !== 'ok') out.push(T('⟳ ' + sent.state, { color: 'cyan', wrap: 'wrap' }))
  } else if (s.ctx > 0 && s.win > 0) {
    const pct = (s.ctx * 100) / s.win
    const label = k(s.ctx) + '/' + k(s.win) + ' ' + Math.round(pct) + '%'
    const barW = Math.max(6, W - 8 - label.length)
    const c = pct >= CTX_RED * 100 ? 'red' : pct >= CTX_AMBER * 100 ? 'yellow' : 'green'
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T('ctx   ', { dimColor: true }),
        gauge(T, pct, barW, c, [CTX_AMBER * 100, CTX_RED * 100]),
        T(label, { color: c }),
      ],
    }))
    // What the two ticks are, in this model's tokens.
    out.push(Box({
      flexDirection: 'row', flexWrap: 'wrap', columnGap: 2, children: [
        T([T('│ ', { color: 'yellow' }), T('expensive from ' + k(s.win * CTX_AMBER), { dimColor: true })]),
        T([T('│ ', { color: 'red' }), T('wasteful from ' + k(s.win * CTX_RED), { dimColor: true })]),
      ],
    }))
    if (s.compacting) out.push(T('  ⟳ a summary is ready: the next prompt compacts', { color: 'cyan' }))
  }

  // Context per turn, with compactions marked; cost per turn underneath.
  if (turns.length >= 3) {
    const cols = Math.max(10, W - 7)
    const shown = turns.slice(-cols)
    const ctxs = shown.map((t) => t[1])
    const drops = new Set()
    for (let i = 1; i < shown.length; i++) if (shown[i][1] < shown[i - 1][1] * 0.6) drops.add(i)
    const win = s.win || 0
    const ctxColour = (v) => (!win ? 'blue' : v >= win * CTX_RED ? 'red' : v >= win * CTX_AMBER ? 'yellow' : 'blue')
    out.push(Box({
      flexDirection: 'row', columnGap: 1, marginTop: 1, children: [
        T('growth', { dimColor: true }),
        spark(T, ctxs, (v, i) => (drops.has(i) ? 'cyan' : ctxColour(v)), 0),
      ],
    }))
    const costs = shown.map((t) => (t[4] == null ? 0 : t[4]))
    const med = median(costs.filter((c) => c > 0))
    // A row's bars reach the cell's foot and the next row's reach its head,
    // so stacked directly they read as one shape: a blank row between each.
    out.push(Box({
      flexDirection: 'row', columnGap: 1, marginTop: 1, children: [
        T('$/turn', { dimColor: true }),
        spark(T, costs, (v) => (med > 0 && v > med * 4 ? 'red' : med > 0 && v > med * 2 ? 'yellow' : 'green'), 0),
      ],
    }))
    const cache = turns.slice(-20).filter((t) => !t[6]).map((t) => t[3])
    if (cache.length > 0) {
      const avg = cache.reduce((a, b) => a + b, 0) / cache.length
      const label = Math.round(avg) + '% hit'
      out.push(Box({
        flexDirection: 'row', columnGap: 1, marginTop: 1, children: [
          T('cache ', { dimColor: true }),
          gauge(T, avg, Math.max(6, W - 8 - label.length), avg >= 90 ? 'green' : avg >= 75 ? 'yellow' : 'red', []),
          T(label, { dimColor: true }),
        ],
      }))
    }
  }
  return out
}

// ---- Claude Burst: this session's context as its gateway sends it

// One colour per part, in the gateway's order.
const PART_COLOURS = {
  'System prompt': 'ansi256(244)', // mid grey: 237 vanished into a dark terminal
  'System tools': 'cyan',
  'MCP tools': 'magenta',
  'Memory files': 'yellow',
  'Messages': 'blue',
  'Tool results': 'green',
}

// What is left of the bar: white, the one colour no part has.
const FREE_COLOUR = 'white'

// The context Burst sends for this session as a stacked bar against the
// model's window, with a line where Burst compacts (the limit is a setting,
// not the room there is), a legend under it, and
// what Claude Code itself still holds when that is more. Without a window
// the bar is against the compaction limit alone.
function sentBar(Box, T, s, W, win, warnPct) {
  const limit = s.compact_at > 0 ? s.compact_at : 0
  const warn = limit ? Math.round((limit * (warnPct > 0 && warnPct < 100 ? warnPct : 80)) / 100) : 0
  const whole = win > limit && win >= s.context
  const scale = whole ? win : Math.max(limit, s.context)
  const pct = Math.round((s.context * 100) / scale)
  const label = k(s.context) + (whole || limit ? '/' + k(scale) + ' ' + pct + '%' : '')
  const colour = limit && s.context >= limit ? 'red' : warn && s.context >= warn ? 'yellow' : undefined
  // Largest first, bar and legend alike: what to cut is read off the left.
  const parts = (s.parts || []).filter((p) => p.tokens > 0).sort((a, b) => b.tokens - a.tokens)
  const barW = Math.max(6, W - 8 - label.length)
  const free = scale - s.context
  let bar
  if (parts.length === 0) {
    bar = gauge(T, pct, barW, colour || 'blue', whole ? [(limit * 100) / scale] : [])
  } else {
    // What is used takes its true share of the bar, so it meets the two
    // lines where it should; the parts share that, the smallest giving way
    // when there are more parts than cells (the legend still names them).
    const used = free > 0 ? Math.max(1, Math.min(barW - 1, Math.round((s.context * barW) / scale))) : barW
    const onBar = parts.slice(0, used)
    const widths = share(onBar.map((p) => p.tokens), used)
    const cells = []
    onBar.forEach((p, i) => { for (let n = 0; n < widths[i]; n++) cells.push(['█', PART_COLOURS[p.name]]) })
    while (cells.length < barW) cells.push(['█', FREE_COLOUR])
    // The two lines, over whatever is in that cell: still there once passed.
    if (whole) {
      const at = (tokens) => Math.max(1, Math.min(barW - 1, Math.round((tokens * barW) / scale)))
      const stop = at(limit)
      // A whole cell in red, the one colour no part has: a line glyph lets
      // the terminal's background through on both sides of it.
      if (stop < cells.length) cells[stop] = ['█', 'red']
    }
    const segs = []
    for (const [ch, c] of cells) {
      const last = segs[segs.length - 1]
      if (last && last.ch === ch && last.c === c) last.text += ch
      else segs.push({ ch, c, text: ch })
    }
    bar = T(segs.map((g) => T(g.text, { color: g.c })))
  }
  const out = [Box({ flexDirection: 'row', columnGap: 1, children: [T('ctx   ', { dimColor: true }), bar, T(label, { color: colour })] })]
  if (parts.length > 0) {
    const key = parts.map((p) => [PART_COLOURS[p.name], p.name + ' ' + k(p.tokens)])
    // The rest of the bar is room left, in the window or before Burst
    // compacts: named, last.
    if (free > 0) key.push([FREE_COLOUR, 'Free ' + k(free)])
    out.push(Box({
      flexDirection: 'row', flexWrap: 'wrap', columnGap: 2, children: key.map(([c, text]) =>
        T([T('■ ', { color: c }), T(text, { dimColor: true })])),
    }))
  }
  if (whole) {
    out.push(Box({
      flexDirection: 'row', flexWrap: 'wrap', columnGap: 2, children: [
        T([T('■ ', { color: 'red' }), T('Burst compacts at ' + k(limit), { dimColor: true })]),
      ],
    }))
  }
  // Claude Code's own history, which Burst's compaction never shrinks. The
  // gap is the tool working, so it is one short line in orange, a colour no
  // warning here uses. Said only once the two have parted.
  if (s.raw > s.context * 1.1) {
    out.push(T('Claude Code Cache Size: ' + k(s.raw), { color: HELD_COLOUR }))
  }
  return out
}

// `width` cells shared out in proportion, every amount above zero getting at
// least one: a part too small for a cell, or the last of the room left, is
// still on the bar. What that costs comes off the widest.
export function share(amounts, width) {
  const total = amounts.reduce((a, b) => a + b, 0)
  if (!(total > 0) || width <= 0) return amounts.map(() => 0)
  const ideal = amounts.map((a) => (a * width) / total)
  const out = ideal.map((x, i) => (amounts[i] > 0 ? Math.max(1, Math.round(x)) : 0))
  let sum = out.reduce((a, b) => a + b, 0)
  while (sum > width) {
    const i = out.indexOf(Math.max(...out))
    if (out[i] <= 1) break
    out[i]--
    sum--
  }
  while (sum < width) {
    let best = 0
    out.forEach((_, i) => { if (ideal[i] - out[i] > ideal[best] - out[best]) best = i })
    out[best]++
    sum++
  }
  return out
}

const HELD_COLOUR = 'ansi256(208)' // orange

// Burst's rows for This Mac, under the panel's Proxy State: a dashboard that
// is not answering, and each problem still standing.
function burstRows(Box, T, burst) {
  if (!burst) return []
  if (burst.down || !burst.mod) return [T('⚡ Burst dashboard not answering', { color: 'red', bold: true, wrap: 'wrap' })]
  return (burst.mod.problems || []).map((p) => {
    const c = p.severity === 'error' ? 'red' : 'yellow'
    return Box({ flexDirection: 'row', children: [T('⚠ ', { color: c }), T(p.title, { color: c, bold: true, wrap: 'wrap' })] })
  })
}

// ---- plan utilisation: the plan's limits, and what the month's use is worth

function planSection(Box, T, d, W, now, limits) {
  const plan = planOf(d.summary)
  const rows = (limits || []).filter((l) => l.reset > now)
  const hasBurst = !!(d.burst && d.burst.dashboard)
  if (rows.length === 0 && !plan) return []
  const out = [heading(T, 'Plan Utilisation', plan ? plan.label : '')]
  const nameW = Math.max(0, ...rows.map((l) => limitName(l.key).length))
  const labelOf = (l) => lpad(Math.round(l.util * 100) + '%', 4) + '  resets ' + when(l.reset, now)
  // One bar width for every row, so the bars can be compared.
  const labelW = Math.max(0, ...rows.map((l) => labelOf(l).length))
  for (const l of rows) {
    const pct = Math.round(l.util * 100)
    const c = pct >= LIMIT_ALARM * 100 ? 'red' : pct >= LIMIT_WARN * 100 ? 'yellow' : 'green'
    out.push(Box({
      flexDirection: 'row', columnGap: 1, children: [
        T(pad(limitName(l.key), nameW), { dimColor: true }),
        gauge(T, pct, Math.max(6, W - nameW - 2 - labelW), c, [LIMIT_WARN * 100]),
        T(labelOf(l), { color: c === 'green' ? undefined : c }),
      ],
    }))
  }
  if (rows.length === 0) {
    out.push(T(hasBurst ? 'No limit reading yet: it comes with the next reply.' : 'How much of the limits is used comes from Claude Burst, which reads it off Anthropic\'s replies.', { dimColor: true, wrap: 'wrap' }))
  }
  // What the flat price buys: the month's use at pay-as-you-go rates.
  if (plan && plan.price > 0 && d.month > 0) {
    out.push(T([
      T(money(d.month), { bold: true }),
      T(' at API rates this month (' + money(plan.price) + ' plan)', { dimColor: true }),
    ], { wrap: 'wrap' }))
  }
  return out
}

// ---- today

function todaySection(Box, T, d, W, now) {
  const t = d.today || {}
  const b = d.block || {}
  const out = [heading(T, 'Today', 'all sessions')]
  if (t.unpriced && !(t.cost > 0)) {
    out.push(T('? unpriced model today: ' + t.unpriced, { color: 'yellow', wrap: 'wrap' }))
  } else {
    out.push(T([
      T(money(t.cost, 2), { bold: true, color: TIER[t.tier] }),
      t.pred != null ? T('  → ' , { dimColor: true }) : '',
      t.pred != null ? T(money(t.pred, 2), { color: TIER[t.pred_tier] }) : '',
      t.pred != null ? T(' by end of day', { dimColor: true }) : '',
    ], { wrap: 'truncate-end' }))
  }
  // A typical day by hour (30-day average), this hour highlighted.
  if (Array.isArray(d.hourly_avg) && d.hourly_avg.some((v) => v > 0)) {
    const hour = new Date(now * 1000).getHours()
    const cw = Math.max(24, W)
    const hours = stretch(24, cw)
    const vals = hours.map((h) => d.hourly_avg[h])
    const chart = bars(T, Box, vals, 3, (v, i) => (hours[i] === hour ? 'cyan' : hours[i] < hour ? 'blue' : 'gray'))
    out.push(sub(T, 'By hour', '30-day average'))
    out.push(...chart)
    out.push(T(axis(['0h', '6h', '12h', '18h', '23h'], cw), { dimColor: true }))
  }
  if (b.active) {
    const left = b.rem || 0
    const used = Math.max(0, Math.min(1, 1 - left / 300))
    out.push(sub(T, '5h block', hm(left) + ' left'))
    out.push(gauge(T, used * 100, W, 'blue', []))
    out.push(T([
      T(money(b.cost), { color: TIER[b.tier] }),
      T('  ' + money(b.cph, 2) + '/hr', { color: TIER[b.tier] }),
      b.label ? T(' ' + b.label.toLowerCase(), { dimColor: true }) : '',
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
    T('  ' + money(p.avg) + '/day', { color: TIER[p.avg_tier] }),
    trend > 0 ? T('  ' + (trend >= 1 ? '▲ ' : '▼ ') + ratio(trend) + ' vs prior', { color: trend >= 1.5 ? 'yellow' : trend < 1 ? 'green' : undefined }) : '',
  ], { wrap: 'truncate-end' }))
  const cw = Math.max(days.length, W)
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
  out.push(T([T('peak ', { dimColor: true }), T(money(peak.cost) + ' ' + short(peak.d)), T('  this week ', { dimColor: true }), T(money(d.week)), T('  ' + short(days[last].d).split(' ')[1] + ' ', { dimColor: true }), T(money(d.month))], { wrap: 'truncate-end' }))

  // Models: one stacked bar, with a legend.
  const models = {}
  for (const x of days) for (const [m, c] of Object.entries(x.models || {})) models[m] = (models[m] || 0) + c
  const ranked = Object.entries(models).filter(([, c]) => c > 0).sort((a, b) => b[1] - a[1])
  const total = ranked.reduce((a, [, c]) => a + c, 0)
  if (total > 0 && ranked.length > 0) {
    const palette = ['magenta', 'blue', 'yellow', 'green', 'cyan']
    out.push(sub(T, 'By model'))
    const barW = Math.max(10, W)
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
  const out = [heading(T, 'Projects', '30 days')]
  const max = ps[0].cost || 1
  const nameW = Math.min(22, Math.max(...ps.map((p) => p.name.length)))
  const here = (d.session && d.session.folder) || ''
  for (const p of ps) {
    const barW = Math.max(4, W - nameW - 9)
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
  const out = [heading(T, 'Sessions today')]
  const max = top[0].cost || 1
  for (const r of top) {
    const mine = r.sid === d.sid
    const barW = Math.max(4, W - 26)
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
  // The day's dearest turns, whichever session they were in.
  const dear = d.top_turns || []
  if (dear.length > 0) {
    out.push(sub(T, 'Costliest turns today'))
    for (const r of dear) {
      const mine = r.sid === d.sid
      out.push(Box({
        flexDirection: 'row', columnGap: 1, children: [
          T('*' + r.sid.slice(-5), { bold: mine, color: mine ? ACCENT : undefined }),
          T(pad('#' + r.turn, 5), { dimColor: true }),
          T(lpad(money(r.cost, 2), 6), { bold: mine }),
          T(lpad(k(r.ctx), 5), { dimColor: true }),
          T(clock(r.at), { dimColor: true }),
          T(cut(r.folder || '', Math.max(4, W - 33)), { dimColor: true }),
        ],
      }))
    }
  }
  return out
}

// ---- insights: a few plain sentences, only when there is something to say

export function insights(d, now, limits = null, extra = null, burst = null) {
  const out = []
  const s = d.session || {}
  const t = d.today || {}
  const b = d.block || {}
  const turns = (d.turns && d.turns.turns) || []
  const recent = turns.slice(-20).filter((x) => !x[6])

  // How full the context is, and what to do about it. With Claude Burst that
  // is Burst's to manage: say when it will compact. Without, it is the
  // user's: past amber and red, say so and name the commands.
  const sent = burst && !burst.down && burst.mod && burst.mod.session && burst.mod.session.context > 0 ? burst.mod.session : null
  const grow = recent.length >= 5 ? (recent[recent.length - 1][1] - recent[0][1]) / (recent.length - 1) : 0
  if (sent) {
    if (grow > 500 && sent.compact_at > sent.context) {
      const left = Math.round((sent.compact_at - sent.context) / grow)
      out.push({ scope: 'session', tier: 'cyan', icon: '↗', text: 'Grows ' + k(grow) + '/turn: Burst compacts in ~' + left + ' turns.' })
    }
  } else if (s.ctx > 0 && s.win > 0) {
    if (s.ctx >= s.win * CTX_RED) {
      out.push({ scope: 'session', tier: 'red', icon: '!', text: 'Wasteful: every turn re-sends ' + k(s.ctx) + '. /compact now, or /clear and start fresh.' })
    } else if (s.ctx >= s.win * CTX_AMBER) {
      out.push({ scope: 'session', tier: 'yellow', icon: '!', text: 'Getting expensive: every turn re-sends ' + k(s.ctx) + '. /compact, or /clear at a break in the work.' })
    } else if (grow > 500) {
      const left = Math.round((s.win * CTX_AMBER - s.ctx) / grow)
      out.push({ scope: 'session', tier: left < 30 ? 'yellow' : 'cyan', icon: '↗', text: 'Grows ' + k(grow) + '/turn: amber (' + k(s.win * CTX_AMBER) + ') in ~' + left + ' turns.' })
    }
  }

  // A pause that let the cache go: the turn after it re-read little from the
  // cache and cost a multiple of the usual. Not a compaction, which shrinks
  // the context and has its own rows.
  let gapTurn = 0
  if (recent.length >= 5) {
    const med = median(recent.map((x) => x[4]).filter((c) => c != null))
    for (let i = recent.length - 1; i >= 1; i--) {
      const a = recent[i - 1]
      const t = recent[i]
      if (!(a[5] && t[5] && t[5] - a[5] > 300 && t[3] < 50 && t[1] >= a[1] * 0.8 && t[4] != null)) continue
      if (med > 0 && t[4] >= med * 2) {
        gapTurn = t[0]
        const pause = t[5] - a[5]
        out.push({ scope: 'session', tier: 'yellow', icon: '◴', text: 'Turn ' + t[0] + ' came after a ' + (pause < 3600 ? Math.round(pause / 60) + 'm' : hm(pause / 60)) + ' pause and read ' + Math.round(t[3]) + '% from cache: ' + money(t[4], 2) + ' against a ' + money(med, 2) + ' median.' })
      }
      break
    }
  }

  if (recent.length >= 5) {
    const hit = recent.reduce((a, x) => a + x[3], 0) / recent.length
    const costs = recent.map((x) => x[4]).filter((c) => c != null)
    if (hit < 85) {
      out.push({ scope: 'session', tier: 'yellow', icon: '◇', text: 'Cache hit ' + Math.round(hit) + '%: a pause over 5 min re-writes it at ~25× a read.' })
    } else if (costs.length > 0) {
      out.push({ scope: 'session', tier: 'green', icon: '◇', text: 'Median turn ' + money(median(costs), 2) + ' (last 20).' })
    }
    const all = turns.slice(-50).filter((x) => x[4] != null)
    const med = median(all.map((x) => x[4]))
    const worst = all.reduce((a, x) => (a == null || x[4] > a[4] ? x : a), null)
    if (worst && worst[0] !== gapTurn && med > 0 && worst[4] > med * 4 && worst[4] >= 0.05) {
      out.push({ scope: 'session', tier: 'yellow', icon: '▲', text: 'Turn ' + worst[0] + ': ' + money(worst[4], 2) + ', ' + Math.round(worst[4] / med) + '× median, +' + k(worst[2]) + ' context.' })
    }
  }

  if (s.cost != null && s.avg_session > 0 && s.cost > s.avg_session * 3) {
    out.push({ scope: 'session', tier: s.tier || 'yellow', icon: '$', text: ratio(s.cost / s.avg_session) + ' your average session (' + money(s.avg_session, 2) + ', 7 days).' })
  }

  // With Claude Burst: what its compaction has saved this session after the
  // summaries and cache rewrites, and the part that fills most of the context.
  const saved = extra && extra.saved
  if (saved && saved.n > 0 && Math.abs(saved.net) >= 0.01) {
    const times = saved.n + (saved.n === 1 ? ' compaction' : ' compactions')
    if (saved.net > 0) out.push({ scope: 'burst', tier: 'green', icon: '⟳', text: 'Compaction has saved ' + money(saved.net, 2) + ' net this session (' + times + ').' })
    else out.push({ scope: 'burst', tier: 'yellow', icon: '⟳', text: 'Compaction has cost ' + money(-saved.net, 2) + ' more than it has saved so far (' + times + ').' })
  }
  if (sent && sent.context >= 100000 && Array.isArray(sent.parts)) {
    const top = sent.parts.reduce((a, p) => (!a || p.tokens > a.tokens ? p : a), null)
    if (top && top.tokens / sent.context >= 0.5) out.push({ scope: 'burst', tier: 'cyan', icon: '▤', text: top.name + ' are ' + Math.round((top.tokens * 100) / sent.context) + '% of the context sent.' })
  }

  // The plan's limits at the present pace.
  for (const l of limits || []) {
    const len = windowSeconds(l.key)
    if (!len || !(l.reset > now)) continue
    if (l.util >= 1) {
      out.push({ scope: 'plan', tier: 'red', icon: '!', text: 'The ' + limitName(l.key) + ' limit is used up: resets ' + when(l.reset, now) + '.' })
      continue
    }
    const elapsed = len - (l.reset - now)
    if (elapsed < len * 0.1 || l.util < 0.05) continue
    const hit = now + ((1 - l.util) * elapsed) / l.util
    if (hit < l.reset) out.push({ scope: 'plan', tier: l.util >= LIMIT_WARN ? 'red' : 'yellow', icon: '↗', text: 'At this pace the ' + limitName(l.key) + ' limit is reached ' + when(hit, now) + ', ' + hm((l.reset - hit) / 60) + ' before it resets.' })
  }

  const sec = extra && extra.secondary
  if (sec && sec.requests > 0) {
    out.push({ scope: 'today', tier: 'yellow', icon: '⇄', text: sec.requests + (sec.requests === 1 ? ' request' : ' requests') + ' went to the secondary today (' + sec.names.join(', ') + ')' + (sec.usd >= 0.01 ? ': ' + money(sec.usd, 2) + ' on top of the plan.' : '.') })
  }

  if (t.cost != null && t.typical_so_far > 1) {
    const pace = t.cost / t.typical_so_far
    if (pace >= 1.5) out.push({ scope: 'today', tier: pace >= 2 ? 'red' : 'yellow', icon: '◔', text: 'Busy: ' + ratio(pace) + ' a typical day by this hour.' })
    else if (pace <= 0.5) out.push({ scope: 'today', tier: 'green', icon: '◔', text: 'Quiet: ' + Math.round(pace * 100) + '% of a typical day by this hour.' })
  }

  if (b.active && (b.tier === 'red' || b.tier === 'yellow')) {
    out.push({ scope: 'today', tier: b.tier, icon: '≋', text: 'Burning ' + money(b.cph, 2) + '/hr (' + (b.label || '').toLowerCase() + '); block resets in ' + hm(b.rem) + '.' })
  }

  const ps = d.projects || []
  const ptotal = ps.reduce((a, p) => a + p.cost, 0)
  if (ps.length > 1 && ptotal > 0 && ps[0].cost / ptotal >= 0.3) {
    out.push({ scope: 'general', tier: 'cyan', icon: '▣', text: ps[0].name + ': ' + Math.round((ps[0].cost * 100) / ptotal) + '% of project spend.' })
  }

  if (Array.isArray(d.hourly_avg)) {
    let best = 0
    d.hourly_avg.forEach((v, h) => { if (v > d.hourly_avg[best]) best = h })
    if (d.hourly_avg[best] > 0) out.push({ scope: 'general', tier: 'cyan', icon: '◷', text: 'Busiest hour: ' + String(best).padStart(2, '0') + ':00, ~' + money(d.hourly_avg[best]) + '/hr.' })
  }
  // At most three per block, most urgent first, so each block's notes stay
  // a glance rather than a list.
  const per = {}
  return out.filter((t) => (per[t.scope] = (per[t.scope] || 0) + 1) <= 3)
}

// ---- the panel's own turn table and footer rows, colours kept

function turnsTable(T, d) {
  const lines = parseAnsi(d.table || '')
  if (lines.length === 0) return []
  const b = d.block || {}
  // Beside the heading: this session's average cost per turn (one turn is
  // one API reply), and the burn rate of the 5h block across every session.
  const s = d.session || {}
  const all = (d.turns && d.turns.turns) || []
  const n = all.length > 0 ? all[all.length - 1][0] : 0
  const notes = []
  if (s.cost > 0 && n > 0) notes.push('Avg API: ' + money(s.cost / n, 2))
  if (b.active) notes.push('All: ' + money(b.cph, 2) + '/hr')
  const out = [heading(T, 'Turns', notes.join('  '))]
  for (const line of lines.slice(0, 13)) out.push(lineText(T, line))
  return out
}

function footer(Box, T, d) {
  const out = []
  const lines = parseAnsi(d.summary || '')
  const keep = lines.filter((l) => /Proxy State:|License:|no price for/.test(l.text))
  for (const l of keep) {
    // Without the panel's own indent: the rows under these start at the edge.
    const segs = l.segs.filter((g) => g.text.trim() !== '[View]').map((g) => ({ ...g }))
    while (segs.length > 0 && segs[0].text.trim() === '') segs.shift()
    if (segs.length > 0) segs[0].text = segs[0].text.replace(/^\s+/, '')
    out.push(lineText(T, { text: l.text, segs }))
  }
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
    // Six eighths at most: a full block would touch the row above, and the
    // three graphs stacked read as one.
    const level = v <= 0 ? 0 : Math.max(1, Math.round(((v - min) / span) * 6))
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
