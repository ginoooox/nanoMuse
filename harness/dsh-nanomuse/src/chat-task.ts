/** Explicit task.chat routing. Ordinary sync stays authoritative for the transcript. */
import { createHash } from 'node:crypto'
import { HubError, type IncomingCall } from './hub.ts'
import type { RemoteLine, SyncState } from './sync.ts'

export interface ChatTaskOptions {
  state(): { accountId: string; signedIn: boolean; sync: SyncState; taskSessions: readonly string[]; archived: readonly string[] }
  active(): Promise<boolean>
  pull(): Promise<unknown>
  line(sessionId: string, mid: string): RemoteLine | undefined
  isBatchSession?(sessionId: string): boolean
  /** Recheck runtime sync gates, including externally quarantined sessions. */
  acceptsSession?(sessionId: string): boolean
  /** Must atomically reject an existing receipt and durably save before returning. */
  claim(key: string, sessionId: string): Promise<void>
  run(args: Record<string, unknown>, call: IncomingCall, sessionId: string, claim: () => Promise<void>): Promise<Record<string, unknown>>
}

export class ChatTasks {
  constructor(private readonly options: ChatTaskOptions) {}

  async task(args: Record<string, unknown>, call: IncomingCall): Promise<Record<string, unknown>> {
    const cid = String(args.cid ?? '').trim(), mid = String(args.mid ?? '').trim().toLowerCase()
    if (!cid || !mid || cid.length > 128 || mid.length > 128 || /[\r\n]/.test(cid + mid)) throw new HubError('usage', 'cid and mid are required')
    const accountId = this.options.state().accountId
    if (!accountId || !(await this.options.active())) throw new HubError('sync_required', 'conversation sync is required')
    // The phone publishes its line first. Pull it and its context before selecting a session.
    await this.options.pull()
    const resolve = (): string => {
      const s = this.options.state(), sync = s.sync
      if (!s.signedIn || s.accountId !== accountId || sync.accountId !== accountId || !sync.enabled) throw new HubError('sync_required', 'the account or sync state changed')
      const matches = Object.entries(sync.cids).filter(([sid, c]) => c === cid && sync.owners[sid] === accountId)
      if (matches.length !== 1) throw new HubError('no_session', 'the conversation has no unique local session')
      const sid = matches[0]![0]
      if ((!sync.sideChats && sid !== sync.mainSession) || s.taskSessions.includes(sid) || this.options.isBatchSession?.(sid) || this.options.acceptsSession?.(sid) === false || s.archived.includes(sid) || sync.toArchive.includes(sid)) throw new HubError('sync_required', 'the target chat is excluded from ordinary sync')
      const line = this.options.line(sid, mid)
      if (!line || line.role !== 'user' || line.device !== call.from.id || sync.hidden.includes(mid)) throw new HubError('message_missing', 'the original caller message has not reached this chat')
      return sid
    }
    const sid = resolve()
    const receipt = createHash('sha256').update(JSON.stringify([accountId, cid, mid])).digest('hex')
    return this.options.run({ ...args, cid, mid }, call, sid, async () => {
      if (!(await this.options.active()) || resolve() !== sid) throw new HubError('sync_required', 'the route changed before execution')
      await this.options.claim(receipt, sid)
      if (resolve() !== sid) throw new HubError('sync_required', 'the route changed during the durable claim')
    })
  }
}
