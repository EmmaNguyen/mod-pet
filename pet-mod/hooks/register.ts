import type { Hook, Register } from 'claude-code'

import type { PetEvent } from '../types'

/*
 * This mod draws nothing inside Claude: it tells the floating Mochi app (in
 * Documents/Claude Mods/Mochi Desktop) what this chat is doing, and Mochi shows it.
 */

const LOG_SIZE = 50 // how many past notifications each chat keeps for Mochi

// What this chat is doing, kept in $.state so it survives a hot reload
const status = { plugin: 'pet-mod', key: 'status' } as const
const log = { plugin: 'pet-mod', key: 'log' } as const
const waiting = { plugin: 'pet-mod', key: 'waiting' } as const

/** The engine interface a hook receives, for the helper that reports to the floating Mochi */
type Dollar = Parameters<Hook<'turn.complete'>>[0]

const ICONS: Record<PetEvent['kind'], string> = {
  turn: '✓',
  helper: '•',
  task: '⚙',
  routine: '⏰',
  message: '✉',
}

const shorten = (text: string, max = 60) =>
  text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text

/**
 * Claude's answer in one short line: its first real sentence, without code,
 * headings, bullets or other markdown. Empty when the answer has no words.
 */
export const summarize = (answer: string, max = 70): string => {
  const prose = answer
    .replace(/```[\s\S]*?```/g, ' ')
    .split('\n')
    .map(line => line.replace(/^\s*(#+|[-*>]|\d+\.|\|)\s*/, '').trim())
    .find(line => /[A-Za-z]/.test(line) && !line.startsWith('|'))
  if (prose === undefined) return ''
  const plain = prose
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/[*_`]/g, '')
    .replace(/\s+/g, ' ')
  const sentence = /^(.+?[.!?])(\s|$)/.exec(plain)?.[1] ?? plain
  return shorten(sentence.replace(/[.!]$/, ''), max)
}

/** What Claude wants to do while it waits for your OK, in a few words */
export const describeAsk = (tool: string, input: unknown): string => {
  const fields = (input ?? {}) as Record<string, unknown>
  const text = (key: string) => (typeof fields[key] === 'string' ? (fields[key] as string) : undefined)
  const file = (text('file_path') ?? text('notebook_path'))?.split('/').at(-1)
  if (tool === 'Bash' && text('command')) return `Run: ${shorten(text('command')!.split('\n')[0]!, 50)}`
  if ((tool === 'Edit' || tool === 'Write' || tool === 'NotebookEdit') && file) return `Edit ${file}`
  if (tool === 'WebFetch' && text('url')) return `Open ${shorten(text('url')!.replace(/^https?:\/\//, ''), 44)}`
  return `Use ${tool.replace(/^mcp__[^_]+__/, '')}`
}

/** Pulls a one-line summary out of a background-task notification */
export const describeTask = (text: string): string => {
  const state = /<status>([^<]*)<\/status>/.exec(text)?.[1]?.trim()
  const summary = /<summary>([^<]*)<\/summary>/.exec(text)?.[1]?.trim()
  const firstLine = text.replace(/<[^>]+>/g, ' ').trim().split('\n')[0]?.trim() ?? ''
  const line = shorten(summary || firstLine || 'A background task finished')

  return state && !line.toLowerCase().includes(state.toLowerCase()) ? `${line} (${state})` : line
}

// Where this chat reports to the floating Mochi app, worked out on first use
let file: string | undefined
let title = 'Claude'
// The link that opens this chat in the Claude app; a terminal chat has none
let link: string | undefined
// A chat with no project folder runs in a scratch folder the app made; it is named after its first message
let isNoFolder = false
let isNamed = false

/** Works out, once, which file this chat reports to and what to call it */
async function locate($: Dollar): Promise<boolean> {
  if (file !== undefined) return true
  const home = await $.env.get('HOME')
  if (home === undefined) return false
  file = `${home}/.claude/mochi/sessions/${await $.session.id()}.json`
  const cwd = await $.session.cwd()
  isNoFolder = cwd.includes('/scratch-workspaces/')
  title = isNoFolder ? 'Chat with no folder' : (cwd.split('/').filter(Boolean).at(-1) ?? 'Claude')
  const hostId = await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')
  link = hostId?.startsWith('local_') ? `claude://code/continue?session=${hostId}&source=mochi` : undefined
  return true
}

/**
 * Tells the floating Mochi app what this chat is doing: one small file per
 * chat in ~/.claude/mochi/sessions, which the app watches for every chat at once.
 */
async function publish($: Dollar, isEnding = false) {
  if (!(await locate($)) || file === undefined) return
  const { value: current = 'idle' } = await $.state.get(status)
  const { value: events = [] } = await $.state.get(log)
  const { value: asking = '' } = await $.state.get(waiting)
  const updatedAt = await $.clock.now()
  const report = { title, link, status: isEnding ? 'ended' : current, waiting: asking, log: events, updatedAt }
  await $.fs.write(file, JSON.stringify(report))
}

/**
 * Tells the floating Mochi your plan usage the moment Claude reports it: how
 * much of the 5-hour window and of the week is used, and when each resets.
 * One file for every chat, ~/.claude/mochi/usage.json; the newest reading wins.
 */
async function publishUsage($: Dollar, limits: readonly { kind: string; percentUsed: number; resetsAt?: string }[]) {
  const five = limits.find(limit => limit.kind === 'five_hour')
  const week = limits.find(limit => limit.kind === 'seven_day')
  if (five === undefined && week === undefined) return
  const home = await $.env.get('HOME')
  if (home === undefined) return
  const usage = {
    fiveHour: five?.percentUsed,
    fiveHourResetsAt: five?.resetsAt,
    week: week?.percentUsed,
    weekResetsAt: week?.resetsAt,
    at: await $.clock.now(),
  }
  await $.fs.write(`${home}/.claude/mochi/usage.json`, JSON.stringify(usage))
}

/** The floating Mochi app's id, as its build gives it */
const MOCHI_APP = 'local.claude-mods.mochi'

/**
 * Starts the floating Mochi when a Claude chat starts, in the background so
 * she never takes the focus; if she is already running, nothing changes.
 * Found by her app id, or else where she was built, in Documents/Claude Mods.
 */
async function wakeMochi($: Dollar) {
  const byId = await $.process.run(['/usr/bin/open', '-g', '-b', MOCHI_APP], { timeoutMs: 10_000 })
  if (byId.exitCode === 0) return
  const home = await $.env.get('HOME')
  if (home === undefined) return
  await $.process.run(['/usr/bin/open', '-g', `${home}/Documents/Claude Mods/Mochi Desktop/Mochi.app`], {
    timeoutMs: 10_000,
  })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'pet', description: "List this chat's notifications" })
    await publish($).catch(() => undefined)
    void wakeMochi($).catch(() => undefined) // in the background, so the chat never waits on it

    return next(e)
  })

  // Claude reported usage that moved: Mochi shows it at once
  on('session.measure', async ($, e, next) => {
    // Every measurement that carries a reading: a fresh timestamp even when the numbers held still
    if (e.rateLimits.length > 0) await publishUsage($, e.rateLimits).catch(() => undefined)
    return next(e)
  })

  // The chat is closing: the floating Mochi stops watching it
  on('session.end', async ($, e, next) => {
    await publish($, true).catch(() => undefined)
    return next(e)
  })

  // `/pet` lists this chat's notifications; the floating Mochi shows every chat's
  on('command.run', { command: 'pet' }, async $ => {
    const { value: events = [] } = await $.state.get(log)
    if (events.length === 0) return { text: 'Nothing yet. Mochi will tell you when things finish!' }
    return {
      text: events
        .slice()
        .reverse()
        .map(event => `${ICONS[event.kind]} ${event.text}${event.seconds === undefined ? '' : ` · ${event.seconds}s`}${event.detail ? ` — ${event.detail}` : ''}`)
        .join('\n'),
    }
  })

  // Every new turn starts here: your own prompt, or background work arriving
  // in this session (a finished task, a routine firing, another session's message)
  on('prompt.submit', async ($, e, next) => {
    const kind = e.origin.kind
    const entry: PetEvent | undefined =
      kind === 'task-notification'
        ? { kind: 'task', text: describeTask(e.text), at: await $.clock.now() }
        : kind === 'scheduled-trigger'
          ? { kind: 'routine', text: 'A routine started', at: await $.clock.now() }
          : kind === 'peer' || kind === 'peer-send-message'
            ? { kind: 'message', text: `Another session: ${shorten(e.text, 50)}`, at: await $.clock.now() }
            : undefined

    if (entry) {
      const { value: before = [] } = await $.state.get(log)
      await $.state.set(log, [...before, entry].slice(-LOG_SIZE))
    }
    await $.state.set(status, 'running')
    await locate($).catch(() => false)
    if (isNoFolder && !isNamed && kind === 'composer') {
      title = `“${shorten(e.text.trim().split('\n')[0] ?? 'Chat', 32)}”`
      isNamed = true
    }
    await publish($).catch(() => undefined)

    return next(e)
  }).catch(($, e, next) => next(e)) // the pet never gets in the way: on any error, carry on as normal

  // Claude wants your OK before running a tool: the red clock (the floating Mochi tells you)
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)

    if (verdict.decision === 'ask' && e.agentId === undefined) {
      await $.state.set(waiting, describeAsk(e.tool, e.input))
      await $.state.set(status, 'needs-input')
      await publish($).catch(() => undefined)
    }

    return verdict
  }).catch(($, e, next) => next(e)) // the pet never gets in the way: on any error, carry on as normal

  // A question for you, or a tool you just answered: back to work afterwards
  on('tool.call', async ($, e, next) => {
    if (e.tool === 'AskUserQuestion' && e.agentId === undefined) {
      await $.state.set(waiting, `Asks: ${shorten(e.questions[0]?.question ?? 'a question', 50)}`)
      await $.state.set(status, 'needs-input')
      await publish($).catch(() => undefined)
    }

    const ran = await next(e)

    const { value: current = 'idle' } = await $.state.get(status)
    if (current === 'needs-input') {
      await $.state.set(waiting, '')
      await $.state.set(status, 'running')
      await publish($).catch(() => undefined)
    }

    return ran
  }).catch(($, e, next) => next(e)) // the pet never gets in the way: on any error, carry on as normal

  // A turn ended: this session's main answer, or one of its helper agents
  on('turn.complete', async ($, e, next) => {
    const seconds = Math.round(e.durationMs / 1000)
    const isHelper = e.agentId !== undefined
    const isOk = e.reason === 'answer'
    const said = isHelper ? 'Helper done' : isOk ? 'Done' : 'Stopped'
    const detail = isOk ? summarize(e.answer) : e.reason === 'aborted' ? 'Interrupted' : `Ended: ${e.reason}`
    const entry: PetEvent = {
      kind: isHelper ? 'helper' : 'turn',
      text: said,
      detail,
      seconds,
      at: await $.clock.now(),
    }

    const { value: before = [] } = await $.state.get(log)
    await $.state.set(log, [...before, entry].slice(-LOG_SIZE))

    // Ready stays up until your next prompt, like an unread badge
    if (!isHelper) await $.state.set(status, isOk ? 'ready' : 'blocked')
    await publish($).catch(() => undefined)

    return next(e)
  })
}
