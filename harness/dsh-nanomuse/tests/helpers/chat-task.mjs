// A task from another device run in a dsh session: the runner against a fake
// context — session creation and naming, the event frames it streams back in the
// runtime's vocabulary, approvals relayed to the asker and decided by `approve`,
// `stop {call}` cancelling the run, busy and timeout handling, the text of a message
// streamed while the model writes it when the asker asked for that.
import { TaskRunner } from '../../lib/task.js'

/** The slice of a dsh Context the runner touches. */
function fakeContext() {
  const listeners = { 'session/event': [], 'approval/request': [], 'agent/assistant-stream': [] }
  const sessions = new Map()
  const agents = new Map()
  const log = []
  // The workspace registry, as the chats column keeps it: a set of archived ids it can bring back.
  const registry = {
    archivedSessionIds: [],
    unarchived: [],
    async unarchiveSession(sessionId) {
      this.unarchived.push(sessionId)
      this.archivedSessionIds = this.archivedSessionIds.filter((id) => id !== sessionId)
    },
  }
  const ctx = {
    get(name) {
      return name === 'workspaceRegistry' ? registry : undefined
    },
    on(name, listener, prepend) {
      if (prepend) listeners[name].unshift(listener)
      else listeners[name].push(listener)
      return () => {
        const i = listeners[name].indexOf(listener)
        if (i >= 0) listeners[name].splice(i, 1)
      }
    },
    sessions: { get: (id) => sessions.get(id) },
    sessionController: {
      created: [],
      renamed: [],
      async create(request) {
        const sessionId = `session-${this.created.length + 1}`
        this.created.push(request)
        const session = { id: sessionId }
        sessions.set(sessionId, session)
        const agent = {
          id: sessionId,
          status: 'idle',
          session,
          sent: [],
          cancelled: [],
          followup(message) {
            this.sent.push(message)
            this.status = 'running'
          },
          cancel(cause) {
            this.cancelled.push(cause)
          },
        }
        agents.set(sessionId, agent)
        return { sessionId }
      },
      async rename(request) {
        this.renamed.push(request)
        return {}
      },
      async resolveAgent(sessionId) {
        const agent = agents.get(sessionId)
        return agent ? { agent } : { error: new Error('no such session') }
      },
    },
  }
  /** Append one event to a session, as the loop would. */
  const emit = (sessionId, type, data) => {
    for (const fn of [...listeners['session/event']]) fn(sessions.get(sessionId), { type, seq: 1, time: Date.now(), data })
  }
  /** Publish one live model-stream frame, as the agent loop would. */
  const stream = (sessionId, frame) => {
    for (const fn of [...listeners['agent/assistant-stream']]) fn({ agent: agents.get(sessionId), frame })
  }
  /** Ask the answerer chain, as the approval service would. */
  const ask = (sessionId, req) => {
    const chain = [...listeners['approval/request']]
    const run = (i) => (i < chain.length ? chain[i](Object.assign({ agent: agents.get(sessionId) }, req), () => run(i + 1)) : Promise.resolve('unavailable'))
    return run(0)
  }
  return { ctx, emit, ask, stream, agents, log, registry }
}

function fakeCall(id, from = { id: 'phone-1', name: 'Phone', kind: 'phone' }) {
  const events = []
  return { id, from, events, event: (body) => events.push(body) }
}

function runner(h, extra = {}) {
  const notices = []
  const r = new TaskRunner(h.ctx, { deviceName: () => 'Desk', log: (level, text) => h.log.push([level, text]), notice: (from, text) => notices.push([from, text]), ...extra })
  const off = r.attach()
  return { r, off, notices }
}

export { fakeContext, fakeCall, runner }
