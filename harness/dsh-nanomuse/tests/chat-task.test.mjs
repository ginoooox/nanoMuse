import assert from 'node:assert/strict'
import { test } from 'node:test'
import { ChatTasks } from '../lib/chat-task.js'
import { emptyState } from '../lib/sync.js'
import { fakeContext, fakeCall, runner } from './helpers/chat-task.mjs'
import { fakeRelay, fakeSessions, engine, until } from './helpers/chat-sync.mjs'

async function setup() {
  const relay = fakeRelay(), sessions = fakeSessions(), h = fakeContext(), receipts = new Map(), taskSessions = {}
  relay.add('cid-a', 'side', 'A'); relay.add('cid-b', 'side', 'B')
  const midA = relay.say('cid-a', 'user', '@Desk task A')
  const midB = relay.say('cid-b', 'user', '@Desk task B')
  let accountId = 'acc-test', archived = []
  const { engine: sync } = engine(relay, sessions, { state: { ...emptyState(), accountId, sideChats: true },
    options: { isTaskSession: sid => Object.values(taskSessions).includes(sid) } })
  await sync.pull()
  for (let i = 0; i < 2; i++) await h.ctx.sessionController.create({})
  const { r, off } = runner(h, { remember: (k, sid) => { taskSessions[k] = sid } })
  const options = {
    state: () => ({ accountId, signedIn: Boolean(accountId), sync: sync.state, taskSessions: Object.values(taskSessions), archived }),
    active: () => sync.active(), pull: () => sync.pull(),
    acceptsSession: sid => sync.acceptsChatTask(sid),
    line: (sid, mid) => sessions.remote(sid).find(line => line.mid === mid),
    claim: async (key, sid) => {
      if (receipts.has(key)) throw Object.assign(new Error('duplicate'), { code: 'duplicate_task' })
      receipts.set(key, sid)
    },
    run: (args, call, sid, claim) => r.taskInChat(args, call, sid, 'pc-1', claim),
  }
  const router = new ChatTasks(options)
  const sid = cid => Object.entries(sync.state.cids).find(([, c]) => c === cid)?.[0]
  const finish = (id, lineId, text) => {
    h.emit(id, 'assistant/message', { message: { id: lineId, content: [{ type: 'text', text }] } })
    sessions.lines.get(id).push({ id: lineId, role: 'assistant', text, at: Date.now() })
    h.emit(id, 'turn/end', { reason: { kind: 'completed' } })
    h.agents.get(id).status = 'idle'
    sync.turnEnded(id)
  }
  return { relay, sessions, h, receipts, taskSessions, sync, r, options, router, sid, finish, midA, midB,
    switchAccount: id => { accountId = id }, archive: id => { archived = [id] }, done: () => { off(); sync.stop() } }
}

test('task.chat keeps A/B separate, reuses history, preserves manual sync and returns the same answer mid as sync', async () => {
  const f = await setup()
  try {
    const mappings = { ...f.sync.state.cids }, sidA = f.sid('cid-a'), sidB = f.sid('cid-b')
    const a = f.router.task({ cid: 'cid-a', mid: f.midA, text: 'task A' }, fakeCall('a'))
    const b = f.router.task({ cid: 'cid-b', mid: f.midB, text: 'task B' }, fakeCall('b'))
    await until(() => f.r.running === 2 && f.h.agents.get(sidA).sent.length === 1 && f.h.agents.get(sidB).sent.length === 1)
    assert.equal(f.h.agents.get(sidA).sent[0].source.kind, 'nanomuse-sync', 'not another user bubble or an uploaded prompt')
    assert.ok(f.h.agents.get(sidA).sent[0].content[0].text.endsWith('task A'))
    assert.ok(f.sessions.injected.some(([sid, text]) => sid === sidA && text.includes('@Desk task A')), 'original context reached the existing agent')
    f.finish(sidA, 'answer-a', 'answer A'); f.finish(sidB, 'answer-b', 'answer B')
    const [answerA, answerB] = await Promise.all([a, b])
    await f.sync.push()
    for (const result of [answerA, answerB]) {
      const line = f.relay.msgs.get(result.mid)
      assert.ok(line, 'Hub and sync share a stable formal answer id')
      assert.equal(line.cid, result.cid); assert.equal(line.text, result.text)
    }
    const nextMid = f.relay.say('cid-a', 'user', '@Desk continue A')
    const next = f.router.task({ cid: 'cid-a', mid: nextMid, text: 'continue A' }, fakeCall('a2'))
    await until(() => f.h.agents.get(sidA).sent.length === 2)
    f.finish(sidA, 'answer-a2', 'continued A')
    assert.equal((await next).thread, sidA)
    f.sessions.lines.get(sidA).push({ id: 'manual-u', role: 'user', text: 'manual hello', at: Date.now() })
    f.sync.messageSent(sidA)
    f.sessions.lines.get(sidA).push({ id: 'manual-a', role: 'assistant', text: 'manual reply', at: Date.now() })
    f.sync.turnEnded(sidA); await f.sync.push()
    for (const text of ['manual hello', 'manual reply']) assert.ok([...f.relay.msgs.values()].some(m => m.cid === 'cid-a' && m.text === text))
    assert.deepEqual(f.sync.state.cids, mappings); assert.deepEqual(f.taskSessions, {})
    assert.equal(f.sessions.created, 2); assert.equal(f.h.ctx.sessionController.created.length, 2)
    assert.equal(f.h.ctx.sessionController.renamed.length, 0); assert.equal(f.relay.convs.size, 2)
    const count = f.relay.msgs.size
    await f.sync.push(); assert.equal(f.relay.msgs.size, count)
    // Rebuilding the router (as after restart) keeps the durable dispatch receipt.
    await assert.rejects(new ChatTasks(f.options).task({ cid: 'cid-a', mid: f.midA, text: 'replay' }, fakeCall('replay')), { code: 'duplicate_task' })
    assert.equal(f.h.agents.get(sidA).sent.length, 2)
  } finally { f.done() }
})

test('task.chat refuses missing routes, wrong callers, excluded chats and account changes without fallback', async () => {
  for (const kind of ['missing', 'wrong-caller', 'side-off', 'task-session', 'batch-session', 'quarantined', 'archived', 'account', 'missing-message']) {
    const f = await setup()
    try {
      const args = { cid: 'cid-a', mid: f.midA, text: 'do it' }
      if (kind === 'missing') args.cid = 'unknown'
      if (kind === 'wrong-caller') f.options.line = () => ({ role: 'user', device: 'other-phone' })
      if (kind === 'side-off') f.sync.state.sideChats = false
      if (kind === 'task-session') f.taskSessions['old-task'] = f.sid('cid-a')
      if (kind === 'batch-session') f.options.isBatchSession = sid => sid === f.sid('cid-a')
      if (kind === 'quarantined') f.sync.syncs = () => false
      if (kind === 'archived') f.archive(f.sid('cid-a'))
      if (kind === 'account') f.switchAccount('other-account')
      if (kind === 'missing-message') args.mid = 'missing'
      await assert.rejects(f.router.task(args, fakeCall('bad')))
      assert.equal(f.h.agents.get(f.sid('cid-a')).sent.length, 0, kind)
      assert.equal(f.receipts.size, 0); assert.equal(f.h.ctx.sessionController.created.length, 2)
    } finally { f.done() }
  }
})

test('task.chat refuses a busy agent and a failed durable claim before executing', async () => {
  const f = await setup()
  try {
    const agent = f.h.agents.get(f.sid('cid-a')), args = { cid: 'cid-a', mid: f.midA, text: 'go' }
    agent.status = 'running'
    await assert.rejects(f.router.task(args, fakeCall('busy')), { code: 'busy' })
    assert.equal(f.receipts.size, 0)
    agent.status = 'idle'
    f.options.claim = async () => { throw new Error('disk unavailable') }
    await assert.rejects(f.router.task(args, fakeCall('disk')), /disk unavailable/)
    assert.equal(agent.sent.length, 0); assert.equal(f.r.running, 0)
  } finally { f.done() }
})

test('Stop, shutdown, an account switch or quarantine during the durable claim prevents execution', async () => {
  for (const change of ['stop', 'shutdown', 'account', 'quarantine']) {
    const f = await setup()
    try {
      let release, writing = false
      f.options.claim = async () => { writing = true; await new Promise(resolve => { release = resolve }) }
      const call = fakeCall('claim'), args = { cid: 'cid-a', mid: f.midA, text: 'go' }
      const pending = f.router.task(args, call)
      const rejected = assert.rejects(pending)
      await until(() => writing)
      if (change === 'stop') assert.deepEqual(await f.r.stop({ call: call.id }, fakeCall('stop')), { stopped: true })
      else if (change === 'shutdown') f.done()
      else if (change === 'account') f.switchAccount('other-account')
      else f.sync.syncs = () => false
      release(); await rejected
      assert.equal(f.h.agents.get(f.sid('cid-a')).sent.length, 0)
      assert.equal(f.h.agents.get(f.sid('cid-a')).cancelled.length, 0, 'a reserved task must not cancel other work before it starts')
      assert.equal(f.r.running, 0)
    } finally { f.done() }
  }
})

test('a manual turn during a durable claim is not streamed or mistaken for the remote answer', async () => {
  const f = await setup()
  try {
    let release, writing = false
    f.options.claim = async () => { writing = true; await new Promise(resolve => { release = resolve }) }
    const sid = f.sid('cid-a'), call = fakeCall('claim')
    const pending = f.router.task({ cid: 'cid-a', mid: f.midA, text: 'go', stream: true }, call)
    await until(() => writing)
    f.h.emit(sid, 'assistant/message', { message: { id: 'manual', content: [{ type: 'text', text: 'unrelated manual answer' }] } })
    f.h.emit(sid, 'turn/end', { reason: { kind: 'completed' } })
    assert.equal(await f.h.ask(sid, { toolName: 'manual-tool' }), 'unavailable', 'an unrelated manual approval stays local')
    assert.deepEqual(call.events, [])
    release()
    await until(() => f.h.agents.get(sid).sent.length === 1)
    f.finish(sid, 'remote-answer', 'the remote answer')
    assert.equal((await pending).text, 'the remote answer')
  } finally { f.done() }
})

test('the shared main chat routes with side-chat sync off and a concurrent duplicate cannot execute', async () => {
  const f = await setup()
  try {
    const sid = f.sid('cid-a'), args = { cid: 'cid-a', mid: f.midA, text: 'main task' }
    f.sync.state.mainSession = sid
    f.sync.state.sideChats = false
    const pending = f.router.task(args, fakeCall('main'))
    await until(() => f.h.agents.get(sid).sent.length === 1)
    await assert.rejects(f.router.task(args, fakeCall('duplicate')), { code: 'busy' })
    assert.equal(f.h.agents.get(sid).sent.length, 1)
    f.finish(sid, 'main-answer', 'main answer')
    assert.equal((await pending).thread, sid)
    assert.deepEqual(f.taskSessions, {})
  } finally { f.done() }
})
