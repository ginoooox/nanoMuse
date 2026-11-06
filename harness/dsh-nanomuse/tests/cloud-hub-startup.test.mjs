// Session services can become ready while the first hub hello is still in flight.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Service } from '@deepseek-ai/cordis'
import NanomuseCloud from '../lib/cloud.js'

process.env.NANOMUSE_PY = join(tmpdir(), 'nanomuse-runtime-that-does-not-exist')

class FakeSocket {
  readyState = 0
  sent = []
  listeners = { open: [], message: [], close: [], error: [] }
  addEventListener(type, fn) { this.listeners[type].push(fn) }
  send(frame) { this.sent.push(JSON.parse(frame)) }
  open() { this.readyState = 1; for (const fn of this.listeners.open) fn({}) }
  push(frame) { for (const fn of this.listeners.message) fn({ data: JSON.stringify(frame) }) }
  close() { this.readyState = 3; for (const fn of this.listeners.close) fn({ code: 1000 }) }
}

for (const phase of ['opening', 'waiting for welcome', 'connected', 'signed out']) {
  test(`task capabilities are published when sessions initialize while hub is ${phase}`, async () => {
    const home = await mkdtemp(join(tmpdir(), 'nm-hub-startup-'))
    process.env.DSH_HOME = home
    const statePath = join(home, 'cloud.json')
    await writeFile(statePath, '{}')
    const injections = [], dispose = [], sockets = []
    const ctx = {
      reflect: { provide() {} },
      logger: { info() {}, warn() {}, debug() {}, error() {} },
      credentials: { async resolve() {}, async set() {}, async unset() {} },
      settings: { describe: () => [], async update() {}, async mutate() {} },
      get() {},
      on() { return () => undefined },
      inject(deps, fn) { injections.push({ deps, fn }) },
      effect(fn) { const cleanup = fn(); if (typeof cleanup === 'function') dispose.push(cleanup) },
      sessionController: { async list() { return { items: [] } } },
    }
    const cloud = new NanomuseCloud(ctx, { baseURL: 'https://relay.invalid', deviceName: 'Desk', statePath })
    cloud.refresh = async () => cloud.status()
    cloud.hub.options.key = async () => 'test-key'
    cloud.hub.options.socket = () => { const socket = new FakeSocket(); sockets.push(socket); return socket }
    try {
      await cloud[Service.init]()
      const sessions = injections.find(({ deps }) => deps.includes('sessionController') && deps.includes('approval'))
      assert.ok(sessions, 'the real session-service initialization callback was registered')
      if (phase === 'signed out') {
        sessions.fn(ctx)
        await new Promise(resolve => setImmediate(resolve))
        assert.equal(sockets.length, 0, 'session initialization must leave the signed-out hub stopped')
        return
      }
      cloud.hub.start()
      await new Promise(resolve => setImmediate(resolve))
      const first = sockets[0]
      if (phase !== 'opening') first.open()
      if (phase === 'connected') first.push({ type: 'welcome', device_id: 'pc-test', devices: [], server: {} })
      cloud.state.account = { id: 'test-account' }
      cloud.state.sync = { enabled: false }
      sessions.fn(ctx)
      await new Promise(resolve => setImmediate(resolve))
      assert.equal(first.readyState, 3, 'the stale hello must be replaced even before welcome arrives')
      assert.equal(sockets.length, 2)
      sockets[1].open()
      const actions = sockets[1].sent[0].device.actions
      for (const action of ['task', 'stop', 'approve', 'task.chat']) assert.ok(actions.includes(action), action)
      assert.equal(cloud.hub.handlers.has('task.chat'), true)
    } finally {
      cloud.hub.stop()
      for (const cleanup of dispose.reverse()) await cleanup()
      await cloud.relayDoor.close()
      await rm(home, { recursive: true, force: true })
    }
  })
}
