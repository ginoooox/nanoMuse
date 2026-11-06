// Conversations synced between the account's devices (contracts C7 and C8) on the desktop: the
// engine against a fake relay and fake sessions — the person's words pushed when sent and the
// model's at the turn's end, the whole history backfilled oldest first, the main chat as the
// account's one main conversation (adopted, merged in time order, our echo never twice), the
// other devices' chats as sessions here from the moment they are pulled, tombstones, the
// switch and the refusals. Contract C9: the side-chat switch (scope), the first pull's tail,
// the working presence both ways, and the host doing no work while nothing changes.
import assert from 'node:assert/strict'
import { SyncEngine, SyncRelay, emptyState } from '../../lib/sync.js'

const tick = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms))
async function until(pred, ms = 2000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (pred()) return
    await tick()
  }
  assert.fail('condition not met in time')
}

/** The relay's /v1/sync/* with the contract's rules, behind a fetch. */
function fakeRelay() {
  const r = { enabled: true, seq: 0, convs: new Map(), msgs: new Map(), pushes: [], calls: [], gets: [], refuse: null, refusePush: null, refuseAll413: 0, working: [], refuseWorking: false, presence: new Map() }
  const next = () => ++r.seq
  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
  const state = () => ({ enabled: r.enabled, cursor: r.seq, counts: { conversations: [...r.convs.values()].filter((c) => !c.deleted).length, messages: r.msgs.size }, limits: {}, working: [...r.presence.values()] })
  r.add = (cid, kind, title, device = 'phone-1', name = 'Pixel 8') => {
    r.convs.set(cid, { cid, kind, title, device, device_name: name, created_at: 1738000000, updated_at: 1738000000, deleted: false, seq: next() })
  }
  r.say = (cid, role, text, device = 'phone-1', name = 'Pixel 8', at = 1738000050) => {
    const mid = `m-${r.seq + 1}`
    r.msgs.set(mid, { mid, cid, seq: next(), device, device_name: name, role, text, truncated: false, attachments: [], created_at: at, deleted: false })
    return mid
  }
  r.tombstone = (cid) => {
    const c = r.convs.get(cid)
    Object.assign(c, { deleted: true, title: '', seq: next() })
    for (const [mid, m] of r.msgs) if (m.cid === cid) r.msgs.delete(mid)
  }
  r.fetch = async (url, init = {}) => {
    const u = new URL(url)
    const method = init.method ?? 'GET'
    const path = u.pathname
    r.calls.push(`${method} ${path}`)
    if (r.refuse) {
      const { status, code } = r.refuse
      r.refuse = null
      return json(status, { error: { code, message: code } })
    }
    if (!init.headers?.authorization) return json(401, { error: { code: 'bad_key', message: 'no key' } })
    if (path === '/v1/sync/state' && method === 'GET') return json(200, state())
    if (path === '/v1/sync/state' && method === 'PUT') {
      r.enabled = JSON.parse(init.body).enabled !== false
      if (!r.enabled) { r.convs.clear(); r.msgs.clear() }
      return json(200, state())
    }
    if (!r.enabled) return json(409, { error: { code: 'sync_off', message: 'off' } })
    if (path === '/v1/sync/changes' && method === 'GET') {
      const since = Number(u.searchParams.get('since') ?? 0)
      const limit = Number(u.searchParams.get('limit') ?? 500)
      // C9: scope=main is the main conversation alone; tail=K (with since=0) the newest K messages of the scope and their conversations
      const scope = u.searchParams.get('scope') ?? 'all'
      const tail = since === 0 ? Number(u.searchParams.get('tail') ?? 0) : 0
      r.gets.push({ since, limit, scope, tail })
      const inScope = (cid) => scope !== 'main' || r.convs.get(cid)?.kind === 'main'
      const convs = [...r.convs.values()].filter((c) => inScope(c.cid))
      const msgs = [...r.msgs.values()].filter((m) => inScope(m.cid))
      if (tail > 0) {
        const newest = msgs.sort((a, b) => a.seq - b.seq).slice(-tail)
        const cids = new Set(newest.map((m) => m.cid))
        return json(200, { cursor: r.seq, more: false, skipped: msgs.length - newest.length, conversations: convs.filter((c) => cids.has(c.cid)), messages: newest })
      }
      const rows = [...convs.map((c) => ['c', c]), ...msgs.map((m) => ['m', m])].filter(([, x]) => x.seq > since).sort((a, b) => a[1].seq - b[1].seq)
      const more = rows.length > limit
      const page = rows.slice(0, limit)
      return json(200, { cursor: more ? page[page.length - 1][1].seq : r.seq, more, conversations: page.filter(([k]) => k === 'c').map(([, x]) => x), messages: page.filter(([k]) => k === 'm').map(([, x]) => x) })
    }
    if (path === '/v1/sync/working' && method === 'POST') {
      if (r.refuseWorking) return json(500, { error: { code: 'boom', message: 'no' } })
      const body = JSON.parse(init.body)
      r.working.push(body)
      if (body.working) r.presence.set(body.cid, { cid: body.cid, from: body.device, device_name: 'Desk', at: Math.floor(Date.now() / 1000) })
      else r.presence.delete(body.cid)
      return new Response(null, { status: 204 })
    }
    if (path === '/v1/sync/changes' && method === 'POST') {
      const body = JSON.parse(init.body)
      r.pushes.push(body)
      if (r.refusePush) {
        const { status, code } = r.refusePush
        r.refusePush = null
        return json(status, { error: { code, message: code } })
      }
      if (r.refuseAll413 && (body.messages ?? []).some((m) => m.text === 'x'.repeat(10))) return json(413, { error: { code: 'too_large', message: 'too large' } })
      let accepted = 0
      const rejected = []
      const redirected = new Map()
      for (const c of body.conversations ?? []) {
        if (!r.convs.has(c.cid)) {
          if (c.kind === 'main') {
            const main = [...r.convs.values()].find((x) => x.kind === 'main' && !x.deleted)
            if (main) { redirected.set(c.cid, main.cid); rejected.push({ cid: c.cid, reason: 'main_exists', cid_main: main.cid }); continue }
          }
          r.convs.set(c.cid, { cid: c.cid, kind: c.kind ?? 'side', title: c.title ?? '', device: body.device, device_name: 'Desk', created_at: c.created_at ?? 0, updated_at: c.updated_at ?? 0, deleted: false, seq: next() })
          accepted++
        } else if (c.title !== r.convs.get(c.cid).title) {
          Object.assign(r.convs.get(c.cid), { title: c.title, seq: next() })
          accepted++
        }
      }
      for (const m of body.messages ?? []) {
        if (redirected.has(m.cid)) { rejected.push({ mid: m.mid, reason: 'main_exists', cid_main: redirected.get(m.cid) }); continue }
        if (r.msgs.has(m.mid)) continue
        if (!r.convs.has(m.cid)) { rejected.push({ mid: m.mid, reason: 'unknown_cid' }); continue }
        r.msgs.set(m.mid, { mid: m.mid, cid: m.cid, seq: next(), device: body.device, device_name: 'Desk', role: m.role, text: m.text, truncated: false, attachments: [], created_at: m.created_at ?? 0, deleted: false })
        accepted++
      }
      return json(200, { cursor: r.seq, accepted, rejected })
    }
    if (path === '/v1/sync/changes' && method === 'DELETE') {
      r.convs.clear()
      r.msgs.clear()
      return json(200, state())
    }
    if (path.startsWith('/v1/sync/conversations/') && method === 'DELETE') {
      const cid = decodeURIComponent(path.split('/').pop())
      if (!r.convs.has(cid)) return json(404, { error: { code: 'no_conversation', message: 'none' } })
      r.tombstone(cid)
      return json(200, { cursor: r.seq, deleted: true })
    }
    return json(404, { error: { code: 'not_found', message: path } })
  }
  return r
}

/** The sessions as the engine sees them: titles, lines, creation, the rows kept from elsewhere, the notes to the model. */
function fakeSessions() {
  const s = { rows: new Map(), lines: new Map(), appended: [], forgotten: [], injected: [], renamed: [], created: 0, listCalls: 0, lineCalls: 0 }
  s.add = (id, title, lines = [], createdAt = 1738000000000) => {
    s.rows.set(id, { id, title, blank: lines.length === 0, createdAt, updatedAt: createdAt })
    s.lines.set(id, lines)
  }
  s.api = {
    list: async () => { s.listCalls += 1; return [...s.rows.values()] },
    lines: async (id) => { s.lineCalls += 1; return s.lines.get(id) ?? [] },
    create: async (title) => {
      const id = `session-${++s.created}`
      s.add(id, title, [], Date.now())
      return id
    },
    rename: async (id, title) => { s.renamed.push([id, title]); if (s.rows.has(id)) s.rows.get(id).title = title },
    keep: async (id, line) => { s.appended.push([id, line]) },
    forget: async (id, mid) => { s.forgotten.push([id, mid]) },
    forgetAll: async () => { s.forgotAll += 1 },
    inject: async (id, text) => { s.injected.push([id, text]) },
  }
  s.forgotAll = 0
  /** What one session shows from elsewhere, in the order it was kept. */
  s.remote = (id) => s.appended.filter(([sid]) => sid === id).map(([, line]) => line)
  return s
}

/** The C7/C8 tests ran with every chat syncing; C9's default (main only) is tested on its own below. */
function engine(relay, sessions, extra = {}) {
  let saved
  let changes = 0
  const e = new SyncEngine({
    relay: new SyncRelay('https://relay.test', relay.fetch),
    sessions: sessions.api,
    token: async () => (extra.signedOut ? undefined : 'key'),
    deviceId: () => 'pc-1',
    isTaskSession: (id) => id.startsWith('task-'),
    isBatchSession: (id) => id.startsWith('batch-'),
    load: () => extra.state ?? { ...emptyState(), sideChats: extra.sideChats ?? true },
    save: async (state) => { saved = JSON.parse(JSON.stringify(state)) },
    onChange: () => { changes += 1 },
    log: () => undefined,
    pushDelayMs: 5,
    pullEveryMs: 60_000,
    frameCoalesceMs: 5,
    ...extra.options,
  })
  return { engine: e, saved: () => saved, changes: () => changes }
}


export { fakeRelay, fakeSessions, engine, until }
