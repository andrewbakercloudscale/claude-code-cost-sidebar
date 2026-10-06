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
const SHOW_COMMAND = 'show-cost-panel'
const HIDE_COMMAND = 'hide-cost-panel'
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
const DAY_KEY = 'weekday' // the store's key for today's share of the weekly limit, shared by every session
const PAUSE = 300 // seconds idle after which the prompt cache has expired
const DAY_SHARES = 2 // a toast when one day uses this many days' worth of the weekly limit
const PIN_KEY = 'pinned'
const LAYOUT_KEY = 'layout'
// The sidebar's sections, most specific first. This Mac (proxy state,
// licence, Burst's standing problems, its dashboard button) is third, under
// the turn table: a problem there must not sit below a screen of charts.
// Plan Utilisation is next: how close the plan's limits are. Then, with
// Claude Burst, what its pauseless compaction has saved.
export const SECTIONS = ['session', 'turns', 'mac', 'plan', 'savings', 'today', 'sessions', 'days', 'projects']

let sid = ''
let home = ''
let cwd = ''
let data = null // the panel's last mod/<sid>.json
let raw = ''
let feedError = ''
let pinned = true
// The sidebar has been open in this session: where it is then closed, a
// button above the prompt brings it back. A session that never had it (the
// pin is off) is left without one.
let wanted = false
// The sidebar is drawn: kept here as it opens and closes, since the button
// is drawn from it and a drawing asks the engine nothing.
let up = false
// It was opened and waits undrawn, on a terminal too narrow for a sidebar
// nobody asked for: it is up once it is first drawn.
let waiting = false
let layout = null // { order, hidden } as the person left it
let burst = null // { down, mod }: Burst's /api/mod answer; null without Burst
let burstRaw = ''
let limits = null // [{ key, util, reset }]: the plan's limits, as Anthropic last reported them
let extra = null // { saved, secondary, warn, comp, auto }: Burst's slower figures, the percent of its limit it warns at, and this folder's compaction limit
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
    // The two things people look for first, under names that say them.
    try {
      await $.command.register({ name: SHOW_COMMAND, description: 'Show the cost and usage sidebar in this session', immediate: true })
      await $.command.register({ name: HIDE_COMMAND, description: 'Hide the cost and usage sidebar in this session', immediate: true })
    } catch (err) {
      $.ui.log('could not add /' + SHOW_COMMAND + ' and /' + HIDE_COMMAND + ': ' + err)
    }
    if (pinned) {
      wanted = true
      try {
        up = seat(await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS }))
      } catch (err) {
        $.ui.log('could not open the usage sidebar: ' + err)
      }
    }
    return next(e)
  })

  // Closed by the person's own close mark or key too: the button above the
  // prompt is drawn from whether the sidebar is up.
  // The close itself is never held up by it.
  on('ui.close', ($, e, next) => {
    const out = next(e)
    if (e && e.id === PANE) {
      Promise.resolve(out).then(() => {
        up = false
        waiting = false
        $.ui.invalidate('ui.render')
      }).catch(() => {})
    }
    return out
  })

  // While the sidebar is closed, or waits undrawn on a terminal too narrow
  // for one nobody asked for: one button, under whatever else is there.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const theirs = await next(e)
    if (!wanted || up || (e.props && e.props.hasSurvey)) return theirs
    const { Box, Button } = $.ui.resolve(e)
    const ours = Box({ flexDirection: 'row', children: [Button({ key: 'usage-show', label: 'Show usage sidebar', onPress: () => showPane($) })] })
    return theirs ? Box({ flexDirection: 'column', children: [theirs, ours] }) : ours
  })

  on('command.run', { command: SHOW_COMMAND }, async ($) => {
    await showPane($)
    return {}
  })

  on('command.run', { command: HIDE_COMMAND }, async ($) => {
    await hidePane($)
    return {}
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = String((e && e.args) || '').trim().toLowerCase()
    if (arg === 'pin' || arg === 'unpin') {
      pinned = arg === 'pin'
      try { await $.store.set(PIN_KEY, pinned) } catch (err) { $.ui.log('could not save the pin: ' + err) }
      $.ui.toast(pinned ? 'Usage panel opens in every new session' : 'Usage panel opens only with /' + COMMAND)
      if (pinned) await showPane($)
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
    wanted = true
    up = seat(await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS, focus: true, closeOnEscape: true }))
    $.ui.invalidate('ui.render')
    return {}
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    // One that waited for a wider terminal has its place.
    if (waiting) {
      waiting = false
      up = true
      $.ui.invalidate('ui.render')
    }
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
    // At the top right, where a close mark is looked for. The button above
    // the prompt brings the sidebar back.
    const top = Box({ flexDirection: 'row', justifyContent: 'flex-end', children: [Button({ key: 'usage-hide', label: 'Hide', role: 'dismiss', onPress: () => hidePane($) })] })
    return Box({ flexDirection: 'column', children: [top, ...rows] })
  })
}

// Opens the sidebar beside the session, where a new session opens it: no
// focus taken. The button above the prompt goes as it does.
async function showPane($) {
  wanted = true
  try { up = seat(await $.ui.open({ id: PANE, title: 'Usage', columns: COLUMNS })) } catch (err) { $.ui.toast('could not open the usage sidebar') }
  $.ui.invalidate('ui.render')
}

// Whether the sidebar is drawn, from what $.ui.open answered: not when it
// waits undrawn, on a terminal too narrow for one nobody asked for.
function seat(opened) {
  waiting = !!(opened && opened.isPlaced === false)
  return !waiting
}

// Closes it, for this session only: /usage-panel unpin stops it opening in
// new ones.
async function hidePane($) {
  // Hidden by hand, so it was had: the button above the prompt is the way back.
  wanted = true
  try {
    await $.ui.close({ id: PANE })
    up = false
    waiting = false
  } catch (err) {
    $.ui.log('could not close the usage sidebar: ' + err)
  }
  $.ui.invalidate('ui.render')
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
// they are the burst-session mod's to show.
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
      next = { down: false, mod: { route: m.route, overflow: m.overflow, primary_failing: m.primary_failing, session: m.session, problems: m.problems, handoff: await handoffOn($) } }
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

// Whether Burst's mod hands Burst's summary to Claude Code: on unless the
// dashboard's option is off. Read from Burst's own file, as its mod does;
// /api/mod does not carry it.
async function handoffOn($) {
  try {
    return JSON.parse(await $.fs.read(home + '/.config/claude-burst/mod.json')).handoff !== false
  } catch (err) {
    return true
  }
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
    const week = found.find((l) => l.key === '7d' && l.reset > now)
    if (week) await dayPace($, week, now)
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
  const next = { saved: null, secondary: null, warn: 0, comp: null, auto: null, over: null, by: null, week: null }
  // Where Burst compacts sessions in this folder: one fixed size, the
  // person's own for the repository, or the one Intelligent Compaction Mode
  // has learned for it.
  const at = cwd ? await get('/api/GetAutoCompactionThreshold?folder=' + encodeURIComponent(cwd)) : null
  if (at && typeof at.threshold === 'number' && typeof at.source === 'string') {
    const f = at.failures || {}
    next.auto = { at: at.threshold, source: at.source, fixed: at.fixed || 0, target: at.target || 0, delay: at.delay_minutes || 0, buffer: at.buffer_percent || 0, lost: (f.unpaid || 0) + (f.summary_failed || 0) + (f.unused || 0), attempts: f.attempts || 0 }
  }
  const cfg = state && state.context && state.context.compaction
  if (cfg && cfg.warn_at_percent > 0) next.warn = cfg.warn_at_percent
  const stats = state && state.context && state.context.compaction_stats
  const mine = ((stats && stats.sessions) || []).filter((x) => x && x.session === sid)
  // Every session Burst has compacted, over its window (7 days).
  if (stats && stats.compactions > 0) {
    next.comp = {
      days: (state.context.window_days > 0 && state.context.window_days) || 7,
      n: stats.compactions, saved: stats.saved_usd || 0, summary: stats.summary_usd || 0, rewrite: stats.rewrite_usd || 0,
      net: stats.net_usd || 0, tokens: stats.tokens_not_resent || 0, before: stats.largest_before || 0, after: stats.largest_after || 0,
      daily: (Array.isArray(stats.daily) ? stats.daily : []).filter((x) => x && typeof x.date === 'string').map((x) => ({ d: x.date, net: x.net_usd || 0, n: x.compactions || 0 })),
    }
  }
  // What the secondary's requests would have cost at the price of the model
  // Claude Code asked for, against what the secondary charged.
  const over = state && state.context && state.context.overflow_stats
  if (over && over.requests > 0) {
    next.over = {
      days: (state.context.window_days > 0 && state.context.window_days) || 7,
      n: over.requests, priced: over.priced || 0, list: over.list_usd || 0, paid: over.paid_usd || 0, saved: over.saved_usd || 0,
      daily: (Array.isArray(over.daily) ? over.daily : []).filter((x) => x && typeof x.date === 'string').map((x) => ({ d: x.date, net: x.saved_usd || 0 })),
    }
  }
  if (mine.length > 0) next.saved = { net: mine.reduce((a, x) => a + (x.net_usd || 0), 0), n: mine.reduce((a, x) => a + (x.compactions || 0), 0) }
  if (state && state.today && state.today.SecondaryRequests > 0) {
    const day = new Date(now * 1000)
    const p2 = (n) => String(n).padStart(2, '0')
    const ymd = day.getFullYear() + '-' + p2(day.getMonth() + 1) + '-' + p2(day.getDate())
    const usage = await get('/api/usage?range=custom&limit=1&from=' + ymd + '&to=' + ymd + 'T23:59')
    const others = ((usage && usage.by_provider) || []).filter((x) => x && x.key !== 'anthropic' && x.requests > 0)
    if (others.length > 0) next.secondary = { requests: others.reduce((a, x) => a + x.requests, 0), usd: others.reduce((a, x) => a + (x.usd || 0), 0), names: others.map((x) => x.key) }
  }
  // What used each of the plan's limits, by project: Anthropic's spend in
  // Burst's log since the window opened. Only the plain windows (5h, 7d): a
  // per-model one is a part of the weekly.
  const iso = (sec) => new Date(sec * 1000).toISOString().slice(0, 19) + 'Z'
  const byRepo = (u) => {
    const rows = ((u && u.by_repo) || []).filter((x) => x && x.usd > 0).map((x) => ({ name: x.key || 'no folder', usd: x.usd })).sort((a, b) => b.usd - a.usd)
    return rows.length > 0 ? { rows: rows.slice(0, 8), total: rows.reduce((a, x) => a + x.usd, 0) } : null
  }
  for (const l of limits || []) {
    const len = windowSeconds(l.key)
    if (!/^\d+[hd]$/.test(l.key) || !len || !(l.reset > now) || !(l.util > 0)) continue
    const found = byRepo(await get('/api/usage?range=custom&limit=1&provider=anthropic&from=' + iso(l.reset - len) + '&to=' + iso(now)))
    if (found) next.by = { ...(next.by || {}), [l.key]: found }
  }
  // And the last 7 days by project, to say when the project that leads the
  // 30 days is no longer the one that leads the week. With the names Burst
  // knows, so a project it names differently is not taken for a new one.
  const week = await get('/api/usage?range=7d&limit=1&provider=anthropic')
  const found = byRepo(week)
  if (found) next.week = { ...found, repos: ((week.options && week.options.repos) || []).filter((x) => typeof x === 'string') }
  extra = next.saved || next.secondary || next.warn || next.comp || next.auto || next.over || next.by || next.week ? next : null
  return JSON.stringify(extra) !== before
}

// The warning for a limit that is close: longer on screen from 95%.
function limitToast($, l, now) {
  // A toast is one colour, the engine's: the level is a coloured mark in
  // the text, yellow at the warning and red at the alarm.
  $.ui.toast((l.util >= LIMIT_ALARM ? '🔴 ' : '🟡 ') + 'Plan limit: ' + Math.round(l.util * 100) + '% of the ' + limitName(l.key) + ' limit used, resets ' + when(l.reset, now), { timeoutMs: l.util >= LIMIT_ALARM ? 30000 : 15000 })
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
// How much of the weekly limit today has used, kept in the store so every
// session counts the same day once: the first reading of the day is where
// the day starts (yesterday's last, when there is one in the same week), and
// what was used before a reset in the middle of the day is carried over.
// One toast a day, from whichever session sees it first, when the day has
// used DAY_SHARES days' worth: a week at that pace runs out days early.
async function dayPace($, l, now) {
  const t = new Date(now * 1000)
  const day = t.getFullYear() + '-' + (t.getMonth() + 1) + '-' + t.getDate()
  let s = null
  try { s = await $.store.get(DAY_KEY) } catch (err) { s = null }
  const ok = s && typeof s.day === 'string' && typeof s.base === 'number' && typeof s.last === 'number' && typeof s.reset === 'number'
  const before = JSON.stringify(s)
  const sameWeek = ok && Math.abs(l.reset - s.reset) < 3600
  if (!ok || s.day !== day) s = { day, base: sameWeek ? s.last : l.util, reset: l.reset, carried: 0, last: l.util, warned: false }
  else if (!sameWeek) s = { ...s, carried: s.carried + Math.max(0, s.last - s.base), base: 0, reset: l.reset }
  s.last = l.util
  const used = (s.carried || 0) + Math.max(0, l.util - s.base)
  if (!s.warned && used >= DAY_SHARES / 7) {
    s.warned = true
    $.ui.toast('🟡 Plan pace: ' + Math.round(used * 100) + '% of the weekly limit used today, over ' + DAY_SHARES + " days' share (" + Math.round((DAY_SHARES * 100) / 7) + '%). ' + Math.round(l.util * 100) + '% used, resets ' + when(l.reset, now), { timeoutMs: 30000 })
  }
  if (JSON.stringify(s) !== before) {
    try { await $.store.set(DAY_KEY, s) } catch (err) { $.ui.log("could not save today's share of the weekly limit: " + err) }
  }
}

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
      const body = planSection(Box, T, d, IW, now, limits, extra)
      return body.length > 0 ? [...body, ...notes('plan')] : []
    },
    savings: () => [...savingsSection(Box, T, IW, extra), ...overflowSection(Box, T, IW, extra)],
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
  const room = W - 'Session:'.length - 2 - (id ? id.length + 3 : 0)
  const out = [heading(T, 'Session:', [id, s.folder ? cut(s.folder, Math.max(4, room)) : ''].filter(Boolean).join(' · '))]
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
    else if (sent.state === 'warning') out.push(T('! Close to the limit: ' + limitLabel(sent) + '.', { color: 'yellow', wrap: 'wrap' }))
    // "compacted" is not said: it stays for the rest of the session and the
    // bar, the growth chart and the turn table already show it.
    else if (sent.state && sent.state !== 'ok' && sent.state !== 'compacted') out.push(T('⟳ ' + sent.state, { color: 'cyan', wrap: 'wrap' }))
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
    // The turn after a compaction writes the new context to the cache once,
    // so it costs more by design: cyan like its drop above, never red.
    out.push(Box({
      flexDirection: 'row', columnGap: 1, marginTop: 1, children: [
        T('$/turn', { dimColor: true }),
        spark(T, costs, (v, i) => (drops.has(i) ? 'cyan' : med > 0 && v > med * 4 ? 'red' : med > 0 && v > med * 2 ? 'yellow' : 'green'), 0),
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

// Where Burst compacts this session: what GetAutoCompactionThreshold says
// for this folder, and until it has answered, what the session's own
// figures carry.
function compactAt(s) {
  const a = extra && extra.auto
  if (a && a.at > 0) return a.at
  return s && s.compact_at > 0 ? s.compact_at : 0
}

// Whether the limit is one Intelligent Compaction Mode learned for this
// repository, not the fixed setting: by GetAutoCompactionThreshold, and
// until it has answered, by the session's own figures. A learned limit
// that is the fixed one is the fixed one: Intelligent Compaction Mode goes
// back to it when compacting sooner does not pay, and "Auto Compact at
// 300k (Intelligent)" then named a size nobody learned.
function learnedLimit(s) {
  const a = extra && extra.auto
  if (a) return a.source === 'learned' && a.at > 0 && !(a.fixed > 0 && a.at >= a.fixed)
  return !!(s && s.learned)
}

// "Auto Compact at 300k", the fixed limit and a learned one alike: a
// learned one is told apart by its colour and the word beside it.
function limitLabel(s) {
  return 'Auto Compact at ' + k(compactAt(s))
}

// What stands beside the limit when it is learned: Burst's Intelligent
// Compaction Mode chose it. '' for the fixed one.
function limitNote(s) {
  return learnedLimit(s) ? '(Intelligent)' : ''
}

// The context Burst sends for this session as a stacked bar against the
// model's window, with a line where Burst compacts (the limit is a setting,
// not the room there is), a legend under it, and
// what Claude Code itself still holds when that is more. Without a window
// the bar is against the compaction limit alone.
function sentBar(Box, T, s, W, win, warnPct) {
  const limit = compactAt(s)
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
  {
    // What is used takes its true share of the bar, so it meets the two
    // lines where it should; the parts share that, the smallest giving way
    // when there are more parts than cells (the legend still names them).
    const used = free > 0 ? Math.max(1, Math.min(barW - 1, Math.round((s.context * barW) / scale))) : barW
    // Before Burst has the breakdown by part the used share is one block,
    // on the same bar: the room left and the limit's line look the same.
    const onBar = parts.length > 0 ? parts.slice(0, used) : [{ tokens: s.context }]
    const widths = share(onBar.map((p) => p.tokens), used)
    const cells = []
    onBar.forEach((p, i) => { for (let n = 0; n < widths[i]; n++) cells.push(['█', p.name ? PART_COLOURS[p.name] : colour || 'blue']) })
    while (cells.length < barW) cells.push(['█', FREE_COLOUR])
    // The two lines, over whatever is in that cell: still there once passed.
    if (whole) {
      const at = (tokens) => Math.max(1, Math.min(barW - 1, Math.round((tokens * barW) / scale)))
      const stop = at(limit)
      // A thin red line with an arrow pointing at it, each drawn on the
      // colour of the cell it stands in: on the terminal's own background
      // the line had a dark gap on both sides and cut the bar in two.
      // The line is on the right edge of the cell before the limit, so it
      // stands at the limit itself and touches the arrow's cell.
      if (stop < cells.length) {
        if (stop > 0) cells[stop - 1] = ['▕', 'red', cells[stop - 1][1]]
        cells[stop] = ['◀', 'red', cells[stop][1]]
      }
    }
    const segs = []
    for (const [ch, c, bg] of cells) {
      const last = segs[segs.length - 1]
      if (last && last.ch === ch && last.c === c && last.bg === bg) last.text += ch
      else segs.push({ ch, c, bg, text: ch })
    }
    bar = T(segs.map((g) => T(g.text, g.bg ? { color: g.c, backgroundColor: g.bg } : { color: g.c })))
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
      flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
        T([T('▕◀ ', { color: 'red' }), T(limitLabel(s), learnedLimit(s) ? { color: 'cyan' } : { dimColor: true })]),
        ...(limitNote(s) ? [T(limitNote(s), { dimColor: true })] : []),
      ],
    }))
  }
  // Claude Code's own history, which Burst's compaction never shrinks.
  // Always said: before the two part it is what Burst sends, and a line that
  // came and went read as a figure gone missing. Its colour is how far the
  // two have parted, and what a restart will do about it.
  const held = Math.max(s.raw || 0, s.context || 0)
  if (held > 0) {
    out.push(T('Uncompacted Size: ' + k(held), { color: heldColour(s, held) }))
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

// Where Burst's mod (burst-session, HANDOFF_AT) compacts a session opened
// again with the summary Burst already wrote.
const HANDOFF_AT = 300000

// The colour of Uncompacted Size. Green: Claude Code holds what Burst sends,
// nothing has been compacted. Yellow: Burst sends a summary and Claude Code
// holds more than a tenth above it. Red: it holds enough that opening the
// session again (--resume, --continue) compacts Claude Code's own copy with
// that summary, unless the hand-off is turned off on Burst's dashboard.
function heldColour(s, held) {
  if (!(held > (s.context || 0) * 1.1)) return 'green'
  const handoff = !(burst && burst.mod && burst.mod.handoff === false)
  return handoff && held >= HANDOFF_AT ? 'red' : 'yellow'
}

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

function planSection(Box, T, d, W, now, limits, extra) {
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
  out.push(...limitShares(Box, T, d, W, rows, extra))
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

// What used each limit, by project: the limit's reading shared out by each
// project's cost at API rates since the window opened. An estimate, and
// said to be: Anthropic does not publish how it weighs tokens against a
// limit. The three largest and the rest, this session's project in cyan.
function limitShares(Box, T, d, W, rows, extra) {
  const out = []
  const here = (d.session && d.session.folder) || ''
  for (const l of rows) {
    const by = extra && extra.by && extra.by[l.key]
    if (!by || !(by.total > 0)) continue
    const top = by.rows.slice(0, 3)
    const rest = by.total - top.reduce((a, x) => a + x.usd, 0)
    const list = rest / by.total >= 0.005 ? [...top, { name: 'other', usd: rest, other: true }] : top
    const nameW = Math.min(20, Math.max(...list.map((x) => x.name.length)))
    const barW = Math.max(4, W - nameW - 6)
    out.push(sub(T, 'What used the ' + limitName(l.key) + ' limit', 'est. by cost'))
    for (const x of list) {
      const pts = (x.usd / by.total) * l.util * 100
      const n = Math.max(1, Math.round((x.usd / top[0].usd) * barW))
      const mine = !x.other && x.name === here
      out.push(Box({
        flexDirection: 'row', columnGap: 1, children: [
          T(pad(cut(x.name, nameW), nameW), { bold: mine, color: mine ? ACCENT : undefined, dimColor: !!x.other }),
          T('█'.repeat(Math.min(n, barW)) + ' '.repeat(Math.max(0, barW - n)), { color: mine ? ACCENT : x.other ? 'gray' : 'blue' }),
          T(lpad(pts < 1 ? '<1%' : Math.round(pts) + '%', 4)),
        ],
      }))
    }
  }
  return out
}

// ---- pauseless compaction: what Claude Burst's compaction has saved

// Each turn after a compaction sends the summary in place of the history;
// the saving is what those turns would have cost with the history still in,
// less what the summaries cost to write and the one cache rewrite each
// compaction causes. Burst works it out; this draws it.
function savingsSection(Box, T, W, extra) {
  const c = extra && extra.comp
  if (!c || !(c.n > 0)) return []
  const out = [heading(T, 'Pauseless Compaction', 'last ' + c.days + ' days')]
  out.push(T([
    T(money(Math.abs(c.net)), { bold: true, color: c.net >= 0 ? 'green' : 'red' }),
    T(c.net >= 0 ? ' saved' : ' lost', { color: c.net >= 0 ? 'green' : 'red' }),
    T('  ' + c.n + (c.n === 1 ? ' compaction' : ' compactions'), { dimColor: true }),
    c.n > 0 && c.net > 0 ? T('  ' + money(c.net / c.n, 2) + ' each', { dimColor: true }) : '',
  ], { wrap: 'truncate-end' }))
  // A bar per day, by its size: a day that lost is red, and a week with
  // nothing either way has no chart (it was three blank rows).
  if (c.daily.length >= 2 && c.daily.some((x) => x.net !== 0)) {
    const cw = Math.max(c.daily.length, W)
    const idx = stretch(c.daily.length, cw)
    const last = c.daily.length - 1
    out.push(...bars(T, Box, idx.map((i) => Math.abs(c.daily[i].net)), 3, (v, i) => (c.daily[idx[i]].net < 0 ? 'red' : idx[i] === last ? 'cyan' : 'green')))
    out.push(T(axis([short(c.daily[0].d), 'today'], cw), { dimColor: true }))
  }
  const row = (label, value, colour) => Box({
    flexDirection: 'row', columnGap: 1, children: [T(pad(label, 22), { dimColor: true }), T(lpad(value, 9), { color: colour })],
  })
  out.push(row('Not re-sent', money(c.saved, 2), 'green'))
  out.push(row('Summaries', '-' + money(c.summary, 2)))
  out.push(row('Cache rewrites', '-' + money(c.rewrite, 2)))
  out.push(row('Net', money(c.net, 2), c.net >= 0 ? 'green' : 'red'))
  if (c.tokens > 0) out.push(T(big(c.tokens) + ' tokens not re-sent' + (c.before > c.after && c.after > 0 ? ', largest ' + k(c.before) + ' → ' + k(c.after) : ''), { dimColor: true, wrap: 'truncate-end' }))
  const mine = extra.saved
  if (mine && mine.n > 0) {
    const one = mine.n === 1
    out.push(T([
      T(mine.n + (one ? ' compaction ' : ' compactions ') + (one ? 'has ' : 'have ') + (mine.net >= 0 ? 'saved ' : 'lost '), { dimColor: true }),
      T(money(Math.abs(mine.net), 2), { color: mine.net >= 0 ? 'green' : 'yellow' }),
      T(mine.net >= 0 ? ' this session' : ' so far this session', { dimColor: true }),
    ], { wrap: 'truncate-end' }))
  }
  return out
}

// ---- overflow: what sending requests to the secondary has saved

// Past the plan's limit Burst sends requests to the secondary. The saving
// is what the same tokens would have cost at the price of the model Claude
// Code asked for, less what the secondary charged. Burst works it out.
function overflowSection(Box, T, W, extra) {
  const o = extra && extra.over
  if (!o || !(o.n > 0)) return []
  const good = o.saved >= 0
  const out = [heading(T, 'Overflow to Secondary', 'last ' + o.days + ' days')]
  out.push(T([
    T(money(Math.abs(o.saved)), { bold: true, color: good ? 'green' : 'red' }),
    T(good ? ' saved' : ' lost', { color: good ? 'green' : 'red' }),
    T('  ' + o.n + (o.n === 1 ? ' request' : ' requests'), { dimColor: true }),
  ], { wrap: 'truncate-end' }))
  if (o.daily.length >= 2 && o.daily.some((x) => x.net !== 0)) {
    const cw = Math.max(o.daily.length, W)
    const idx = stretch(o.daily.length, cw)
    const last = o.daily.length - 1
    out.push(...bars(T, Box, idx.map((i) => Math.abs(o.daily[i].net)), 3, (v, i) => (o.daily[idx[i]].net < 0 ? 'red' : idx[i] === last ? 'cyan' : 'green')))
    out.push(T(axis([short(o.daily[0].d), 'today'], cw), { dimColor: true }))
  }
  const row = (label, value, colour) => Box({
    flexDirection: 'row', columnGap: 1, children: [T(pad(label, 22), { dimColor: true }), T(lpad(value, 9), { color: colour })],
  })
  out.push(row('At Anthropic\'s price', money(o.list, 2)))
  out.push(row('Secondary charged', '-' + money(o.paid, 2)))
  out.push(row('Net', money(o.saved, 2), good ? 'green' : 'red'))
  if (o.priced < o.n) out.push(T((o.n - o.priced) + (o.n - o.priced === 1 ? ' request has' : ' requests have') + ' no price and ' + (o.n - o.priced === 1 ? 'is' : 'are') + ' left out', { dimColor: true, wrap: 'truncate-end' }))
  return out
}

// 1.49B, 432M, 86k.
function big(n) {
  return n >= 1e9 ? (n / 1e9).toFixed(2).replace(/\.?0+$/, '') + 'B' : k(n)
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
  // What pauses cost: turns that came after the cache had expired and wrote
  // again what they would have read. The longer figure is the days on file.
  if (t.cache_loss_30 >= 0.01) {
    const n = t.cache_loss_turns || 0
    out.push(T([
      t.cache_loss >= 0.01 ? T(money(t.cache_loss, 2), { color: 'yellow' }) : T('Nothing', { color: 'green' }),
      T(' re-written after ' + (t.cache_loss >= 0.01 ? n + (n === 1 ? ' pause' : ' pauses') : 'a pause today'), { dimColor: true }),
      t.cache_loss_days > 1 ? T(', ' + money(t.cache_loss_30, 2) + ' in ' + t.cache_loss_days + ' days', { dimColor: true }) : '',
    ], { wrap: 'wrap' }))
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

  // Models: a pie, its key beside it.
  const models = {}
  for (const x of days) for (const [m, c] of Object.entries(x.models || {})) models[m] = (models[m] || 0) + c
  const ranked = Object.entries(models).filter(([, c]) => c > 0).sort((a, b) => b[1] - a[1])
  const total = ranked.reduce((a, [, c]) => a + c, 0)
  if (total > 0 && ranked.length > 0) {
    const palette = ['magenta', 'blue', 'yellow', 'green', 'cyan']
    // Five named, the rest as one slice, so every slice has a key.
    const slices = ranked.slice(0, 5).map(([m, c], i) => ({ name: modelName(m), cost: c, colour: palette[i] }))
    const rest = ranked.slice(5).reduce((a, [, c]) => a + c, 0)
    if (rest > 0) slices.push({ name: 'Other', cost: rest, colour: 'gray' })
    out.push(sub(T, 'By model'))
    out.push(Box({
      flexDirection: 'row', columnGap: 2, children: [
        Box({ flexDirection: 'column', children: pie(T, slices.map((x) => [x.colour, x.cost]), PIE_ROWS) }),
        Box({
          // A slice under half a percent is not on the pie: no "0%" row.
          flexDirection: 'column', children: slices.filter((x) => Math.round((x.cost * 100) / total) >= 1).map((x) =>
            T([T('■ ', { color: x.colour }), T(lpad(Math.round((x.cost * 100) / total) + '%', 4) + ' ' + x.name, { dimColor: true })], { wrap: 'truncate-end' })),
        }),
      ],
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
      const why = whyDear(r)
      if (why) out.push(T('       ↳ ' + why, { dimColor: true, wrap: 'truncate-end' }))
    }
  }
  return out
}

// Why a turn was dear, in a few words, from the turn and the one before it
// in its session: r is { ctx, delta (the context it wrote to the cache),
// cache (hit %), out (the reply's tokens), gap (seconds since the turn
// before), prev (that turn's context; 0 for a session's first turn) }.
// '' when the figures are not there (a feed older than this) or nothing
// stands out. What it wrote again, as against what it added, is what a lost
// cache looks like: the context was there before and was paid for twice.
export function whyDear(r) {
  if (!r || r.cache == null || r.delta == null || !(r.ctx > 0)) return ''
  const pause = (sec) => (sec < 3600 ? Math.round(sec / 60) + 'm' : hm(sec / 60))
  if (r.prev === 0 && r.delta >= r.ctx * 0.3 && r.delta >= 5000) return 'first turn: ' + k(r.delta) + ' written to cache'
  if (r.prev > 0) {
    const again = r.delta - Math.max(0, r.ctx - r.prev)
    if (again >= r.ctx * 0.3 && again >= 5000) {
      if (r.ctx < r.prev * 0.6) return 'cache re-written after compaction'
      if (r.gap > PAUSE) return 'cache lost after a ' + pause(r.gap) + ' pause'
      return 'cache missed: ' + k(again) + ' written again'
    }
  }
  // A reply's tokens cost four times what a cache write's do.
  if (r.out >= 2000 && r.out * 4 >= r.delta) return k(r.out) + ' reply'
  if (r.delta >= 10000) return '+' + k(r.delta) + ' context'
  return ''
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
    if (grow > 500 && compactAt(sent) > sent.context) {
      const left = Math.round((compactAt(sent) - sent.context) / grow)
      out.push({ scope: 'session', tier: 'cyan', icon: '↗', text: 'Grows ' + k(grow) + '/turn: Auto Compact in ~' + left + ' turns.' })
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
      if (!(a[5] && t[5] && t[5] - a[5] > PAUSE && t[3] < 50 && t[1] >= a[1] * 0.8 && t[4] != null)) continue
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
    // Not the turn after a compaction: its one cache rewrite is expected.
    const compacted = new Set()
    for (let i = 1; i < turns.length; i++) if (turns[i][1] < turns[i - 1][1] * 0.6) compacted.add(turns[i][0])
    const worst = all.filter((x) => !compacted.has(x[0])).reduce((a, x) => (a == null || x[4] > a[4] ? x : a), null)
    if (worst && worst[0] !== gapTurn && med > 0 && worst[4] > med * 4 && worst[4] >= 0.05) {
      // Why, when the feed carries the reply's size (it is as old as that
      // otherwise, and what the turn wrote is all there is to say).
      const before = turns[turns.indexOf(worst) - 1]
      const why = worst.length > 7 ? whyDear({ ctx: worst[1], delta: worst[2], cache: worst[3], out: worst[7], gap: before && before[5] && worst[5] ? worst[5] - before[5] : null, prev: before ? before[1] : worst[0] === 1 ? 0 : null }) : ''
      out.push({ scope: 'session', tier: 'yellow', icon: '▲', text: 'Turn ' + worst[0] + ': ' + money(worst[4], 2) + ', ' + Math.round(worst[4] / med) + '× median, ' + (why || '+' + k(worst[2]) + ' context') + '.' })
    }
  }

  if (s.cost != null && s.avg_session > 0 && s.cost > s.avg_session * 3) {
    out.push({ scope: 'session', tier: s.tier || 'yellow', icon: '$', text: ratio(s.cost / s.avg_session) + ' your average session (' + money(s.avg_session, 2) + ', 7 days).' })
  }

  // With Claude Burst: the part that fills most of the context.
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

  // What the day's pauses cost, when it is a tenth of the day or more.
  if (t.cache_loss >= 0.5 && t.cost > 0 && t.cache_loss >= t.cost * 0.1) {
    out.push({ scope: 'today', tier: 'yellow', icon: '◴', text: 'Pauses cost ' + money(t.cache_loss, 2) + ' today, ' + Math.round((t.cache_loss * 100) / t.cost) + '% of the day: the cache expires after 5 min idle.' })
  }

  if (b.active && (b.tier === 'red' || b.tier === 'yellow')) {
    out.push({ scope: 'today', tier: b.tier, icon: '≋', text: 'Burning ' + money(b.cph, 2) + '/hr (' + (b.label || '').toLowerCase() + '); block resets in ' + hm(b.rem) + '.' })
  }

  // The two general notes are said only on a change: which project leads
  // and which hour is busiest are the same every day, and a line that is
  // always there is not read.
  // A new top project: the one that leads the last 7 days (Burst's log) is
  // not the one that leads the 30. Only when Burst knows the 30-day leader
  // by the same name, so two spellings of one project are not a change.
  const ps = d.projects || []
  const wk = extra && extra.week
  if (wk && wk.total > 0 && ps.length > 0 && wk.rows[0].name !== ps[0].name && wk.rows[0].usd / wk.total >= 0.3 && (wk.repos || []).includes(ps[0].name)) {
    out.push({ scope: 'general', tier: 'cyan', icon: '▣', text: 'New top project: ' + wk.rows[0].name + ' is ' + Math.round((wk.rows[0].usd * 100) / wk.total) + '% of the last 7 days (' + ps[0].name + ' leads the 30).' })
  }

  // An unusual hour: this session is working (a turn in the last 15
  // minutes) at an hour that averages under a tenth of the busiest one.
  const last = turns.length > 0 ? turns[turns.length - 1][5] : 0
  if (Array.isArray(d.hourly_avg) && d.hourly_avg.length === 24 && last && now - last < 900) {
    const hour = new Date(now * 1000).getHours()
    let best = 0
    d.hourly_avg.forEach((v, h) => { if (v > d.hourly_avg[best]) best = h })
    const h2 = (h) => String(h).padStart(2, '0') + ':00'
    if (d.hourly_avg[best] > 0 && d.hourly_avg[hour] < d.hourly_avg[best] * 0.1) {
      out.push({ scope: 'general', tier: 'cyan', icon: '◷', text: 'Unusual hour: ' + h2(hour) + ' averages ' + money(d.hourly_avg[hour], 2) + '/hr, against ' + money(d.hourly_avg[best]) + ' at ' + h2(best) + '.' })
    }
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
  // Beside the heading, both for every session: today's average cost per
  // turn (one turn is one API reply), and the burn rate of the 5h block.
  const t = d.today || {}
  const notes = []
  if (t.turns > 0 && t.turns_usd > 0) notes.push('Avg API: ' + money(t.turns_usd / t.turns, 2))
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

const PIE_ROWS = 8

// A pie in `rows` rows of text, twice as many cells wide (a cell is about
// twice as tall as it is wide). Slices are [colour, amount], drawn clockwise
// from twelve o'clock in the order given. Each cell is four quarters, drawn
// with a quadrant block in one slice's colour on another's (or on nothing,
// at the rim), so the outline and the cuts are twice as fine as the cells.
const QUADS = [' ', '▘', '▝', '▀', '▖', '▌', '▞', '▛', '▗', '▚', '▐', '▜', '▄', '▙', '▟', '█']
export function pie(T, slices, rows) {
  const total = slices.reduce((a, [, v]) => a + v, 0)
  if (!(total > 0) || rows < 3) return []
  const r = rows / 2
  const at = (x, y) => {
    const dx = x - r
    const dy = y - r
    if (dx * dx + dy * dy > r * r) return null
    let turn = Math.atan2(dx, -dy) / (2 * Math.PI)
    if (turn < 0) turn += 1
    let sum = 0
    for (const [c, v] of slices) {
      sum += v / total
      if (turn < sum) return c
    }
    return slices[slices.length - 1][0]
  }
  const out = []
  for (let row = 0; row < rows; row++) {
    const segs = []
    for (let col = 0; col < rows * 2; col++) {
      // Top left, top right, bottom left, bottom right.
      const q = [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]].map(([qx, qy]) => at((col + qx) / 2, row + qy))
      const count = {}
      for (const c of q) if (c) count[c] = (count[c] || 0) + 1
      const ranked = Object.keys(count).sort((x, y) => count[y] - count[x])
      const fg = ranked[0]
      // At the rim the other colour is the terminal's own; inside, the
      // second slice's. A third slice in one cell goes with the second.
      const bg = q.includes(null) ? undefined : ranked[1]
      let bits = 0
      q.forEach((c, i) => { if (c && (c === fg || bg === undefined)) bits |= 1 << i })
      const key = (fg || '') + '/' + (bg || '')
      const last = segs[segs.length - 1]
      if (last && last.key === key) last.text += QUADS[bits]
      else segs.push({ key, fg, bg, text: QUADS[bits] })
    }
    out.push(T(segs.map((g) => T(g.text, g.bg ? { color: g.fg, backgroundColor: g.bg } : { color: g.fg }))))
  }
  return out
}

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
