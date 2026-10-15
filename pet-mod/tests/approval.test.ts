import { expect, test } from 'bun:test'

import { register } from '../hooks/register'

// Tests for Mochi's Allow, Deny, Accept edits and Auto answers. A stub engine stands in for Claude Code:
// a virtual clock, state and files. `sleep` lets a fake Mochi act between polls, and rejects when the
// hook's signal aborts, as the engine does.

type World = { now: number; state: Map<string, unknown>; files: Map<string, string>; slept: number }
const HOME = '/h'
const presencePath = `${HOME}/.claude/mochi/presence.json`
const answerPath = `${HOME}/.claude/mochi/answers/chat-1.json`

/** A stub engine. `onTick` runs at each poll, so the fake Mochi can write her files */
function world(onTick?: (w: World) => void) {
  const w: World = { now: 1_000_000, state: new Map(), files: new Map(), slept: 0 }
  const tick = () => onTick?.(w)
  tick() // Mochi has already written that she is running, as she does every second
  const $ = {
    env: { get: async (k: string) => (k === 'HOME' ? HOME : undefined) },
    session: { id: async () => 'chat-1', cwd: async () => '/x/garden' },
    clock: {
      now: async () => w.now,
      sleep: async (ms: number, opts?: { signal?: AbortSignal }) => {
        if (opts?.signal?.aborted) throw new Error('aborted')
        w.now += ms
        w.slept += ms
        tick()
        if (opts?.signal?.aborted) throw new Error('aborted')
      },
    },
    state: {
      get: async (k: { key: string }) => ({ value: w.state.get(k.key) }),
      set: async (k: { key: string }, v: unknown) => {
        w.state.set(k.key, v)
      },
    },
    fs: {
      read: async (p: string) => {
        const text = w.files.get(p)
        if (text === undefined) throw new Error('missing')
        return text
      },
      write: async (p: string, text: string) => {
        w.files.set(p, text)
      },
    },
  }
  return { w, $ }
}

/** `next` as the engine gives it: a result, and the signal that aborts the hook */
const next = (result: unknown, signal = new AbortController().signal) => Object.assign(async () => result, { signal })

/** The plugin's handlers, by event name */
function handlers() {
  const map: Record<string, (...args: any[]) => any> = {}
  const on = (name: string, a: any, b?: any) => {
    map[name] = typeof a === 'function' ? a : b
    return { catch: () => undefined }
  }
  register(on as any)
  return map
}

const h = handlers()
const ask = { tool: 'Bash', input: { command: 'npm publish' }, tool_use_id: 'tu-1' }
const asks = { decision: 'ask' }

/** Mochi writes that she is running, shows these requests, and answers the one given */
const mochi = (answer?: { requestId: string; decision: string }, showing = ['tu-1']) => (w: World) => {
  w.files.set(presencePath, JSON.stringify({ at: w.now, pending: showing }))
  if (answer) w.files.set(answerPath, JSON.stringify({ ...answer, at: w.now }))
}

/** Claude's permission dialog is about to show for this call */
const dialog = ($: any, mode = 'default', extra: Record<string, unknown> = {}) =>
  h['classic.PermissionRequest']($, { permission_mode: mode, tool_name: ask.tool, tool_input: ask.input, ...extra }, next({}))

test('no Mochi running: Claude shows its dialog at once', async () => {
  const { w, $ } = world()
  await h['tool.check']($, ask, next(asks))
  const start = w.now
  expect(await dialog($)).toEqual({})
  expect(w.now - start).toBe(0)
})

test('Allow on Mochi allows the call', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'allow' }))
  await h['tool.check']($, ask, next(asks))
  expect((await dialog($)).decision).toEqual({ behavior: 'allow' })
})

test('Deny on Mochi declines the call', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'deny' }))
  await h['tool.check']($, ask, next(asks))
  expect((await dialog($)).decision).toEqual({ behavior: 'deny', message: 'You declined this in Mochi' })
})

test('Mochi running but not showing the request: the dialog shows within about 2 s', async () => {
  const { w, $ } = world(mochi(undefined, []))
  await h['tool.check']($, ask, next(asks))
  const start = w.now
  expect(await dialog($)).toEqual({})
  expect(w.now - start).toBeLessThanOrEqual(2_500)
})

test('no answer: the dialog shows after about 8 s, inside the 10 s hook budget', async () => {
  const { w, $ } = world(mochi())
  await h['tool.check']($, ask, next(asks))
  const start = w.now
  expect(await dialog($)).toEqual({})
  expect(w.now - start).toBeGreaterThanOrEqual(8_000)
  expect(w.now - start).toBeLessThanOrEqual(8_500)
})

test('the engine aborts the hook mid-wait: it stops at once', async () => {
  const controller = new AbortController()
  const { w, $ } = world((x) => {
    mochi()(x)
    if (x.now >= 1_001_000) controller.abort()
  })
  await h['tool.check']($, ask, next(asks))
  const start = w.now
  const result = await h['classic.PermissionRequest']($, { permission_mode: 'default', tool_name: 'Bash', tool_input: ask.input }, next({}, controller.signal))
  expect(result).toEqual({})
  expect(w.now - start).toBeLessThanOrEqual(1_500)
})

test('an answer for a different request is ignored', async () => {
  const { $ } = world(mochi({ requestId: 'old-9', decision: 'allow' }))
  await h['tool.check']($, ask, next(asks))
  expect(await dialog($)).toEqual({})
})

test('a question for you is never answered from Mochi', async () => {
  const question = { tool: 'AskUserQuestion', input: {}, tool_use_id: 'tu-2' }
  const { $ } = world(mochi({ requestId: 'tu-2', decision: 'allow' }, ['tu-2']))
  await h['tool.check']($, question, next(asks))
  expect(await dialog($, 'default', { tool_name: question.tool })).toEqual({})
})

test('a set ceiling decides for itself: Mochi is not offered', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'allow' }))
  await h['tool.check']($, ask, next({ decision: 'ask', ceiling: 'ask' }))
  expect(await dialog($)).toEqual({})
})

test('a helper agent is left to Claude', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'allow' }))
  await h['tool.check']($, ask, next(asks))
  expect(await h['classic.PermissionRequest']($, { permission_mode: 'default', agent_id: 'helper-1', tool_name: 'Bash', tool_input: ask.input }, next({}))).toEqual({})
})

test('the report names the request and the whole command, and clears after the call', async () => {
  const { w, $ } = world()
  await h['tool.check']($, ask, next(asks))
  const report = JSON.parse(w.files.get(`${HOME}/.claude/mochi/sessions/chat-1.json`) ?? '{}')
  expect(report).toMatchObject({ requestId: 'tu-1', askedAt: 1_000_000, waiting: 'Run: npm publish', detail: '$ npm publish' })
  await h['tool.call']($, { ...ask }, async () => ({ result: 'ok' }))
  const after = JSON.parse(w.files.get(`${HOME}/.claude/mochi/sessions/chat-1.json`) ?? '{}')
  expect(after).toMatchObject({ requestId: '', waiting: '' })
})

test('Accept edits from Manual switches this session to Accept edits, and allows the call', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'acceptEdits' }))
  await h['tool.check']($, ask, next(asks))
  const { decision } = await dialog($, 'default')
  expect(decision.behavior).toBe('allow')
  expect(decision.updatedPermissions).toEqual([{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }])
})

test('Accept edits from Plan allows the call and leaves the mode alone', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'acceptEdits' }))
  await h['tool.check']($, ask, next(asks))
  expect((await dialog($, 'plan')).decision).toEqual({ behavior: 'allow', updatedPermissions: undefined })
})

test('Auto from Manual or Accept edits switches this session to Auto', async () => {
  for (const from of ['default', 'acceptEdits']) {
    const { $ } = world(mochi({ requestId: 'tu-1', decision: 'auto' }))
    await h['tool.check']($, ask, next(asks))
    const { decision } = await dialog($, from)
    expect(decision.updatedPermissions).toEqual([{ type: 'setMode', mode: 'auto', destination: 'session' }])
  }
})

test('Auto from Plan allows the call and leaves the mode alone', async () => {
  const { $ } = world(mochi({ requestId: 'tu-1', decision: 'auto' }))
  await h['tool.check']($, ask, next(asks))
  expect((await dialog($, 'plan')).decision).toEqual({ behavior: 'allow', updatedPermissions: undefined })
})
