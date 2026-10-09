import type { On, RenderElement } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { describeAsk, describeTask, summarize } from '../hooks/register'

/** Records the toasts shown and the latest value of each state key the mod writes */
const watch = (on: On) => {
  const toasts: string[] = []
  const state = new Map<string, unknown>()

  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('state.set', (_, e, next) => {
    const write = e as { plugin: string; key: string; value: unknown }
    if (write.plugin === 'pet-mod') state.set(write.key, write.value)
    return next(e)
  })

  return { toasts, state }
}

/** Stands in for the computer: a home folder, a chat id and folder, and the files written */
const computer = (on: On, cwd = '/Users/test/code/garden', env: Record<string, string> = {}) => {
  const files = new Map<string, string>()
  mock.env(on, { HOME: '/Users/test', ...env })
  on('session.id', () => ({ value: 'chat-1' }) as never)
  on('session.cwd', () => ({ value: cwd }) as never)
  on('fs.write', (_, e) => {
    files.set(e.path, e.text)
    return { value: undefined }
  })
  const report = () => JSON.parse(files.get('/Users/test/.claude/mochi/sessions/chat-1.json') ?? '{}')
  return { report }
}

test('a finished turn shows Ready until the next prompt, without toasts in Claude', async ($, on) => {
  mock.clock(on)
  const { toasts, state } = watch(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('prompt.submit', (_, e) => ({ text: e.text }))

  await $.turn.complete({
    answer: 'All fixed.',
    durationMs: 12_000,
    isAborted: false,
    turnId: 'turn-1',
    reason: 'answer',
  })

  expect(toasts).toEqual([]) // Mochi tells you, not Claude
  expect(state.get('status')).toBe('ready')

  await $.prompt.submit({ text: 'next thing', wait: false, origin: { kind: 'composer' } })
  expect(state.get('status')).toBe('running')
})

test('an interrupted turn shows Blocked', async ($, on) => {
  mock.clock(on)
  const { state } = watch(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))

  await $.turn.complete({
    answer: '',
    durationMs: 4_000,
    isAborted: true,
    turnId: 'turn-1',
    reason: 'aborted',
  })

  expect(state.get('status')).toBe('blocked')
})

test('a tool waiting for your OK shows Needs you, then back to work', async ($, on) => {
  mock.clock(on)
  const { state } = watch(on)
  on('tool.check', () => ({ decision: 'ask' }))
  on('tool.call', () => ({ result: 'ok' }))

  await $.tool.check({ tool: 'Bash', input: { command: 'npm publish' } })
  expect(state.get('status')).toBe('needs-input')

  await $.tool.call({ tool: 'Bash', input: { command: 'npm publish' } } as never)
  expect(state.get('status')).toBe('running')
})

test('a helper agent finishing is logged but keeps the status', async ($, on) => {
  mock.clock(on)
  const { state } = watch(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))

  await $.turn.complete({
    answer: 'Searched.',
    durationMs: 3_000,
    isAborted: false,
    turnId: 'turn-2',
    agentId: 'helper-1',
    reason: 'answer',
  })

  expect(state.get('log')).toMatchObject([{ kind: 'helper', text: 'Helper done', detail: 'Searched', seconds: 3 }])
  expect(state.has('status')).toBe(false)
})

test('a background task finishing is logged', async ($, on) => {
  mock.clock(on)
  const { state } = watch(on)
  on('prompt.submit', (_, e) => ({ text: e.text }))

  await $.prompt.submit({
    text: '<task-notification><status>completed</status><summary>Build finished</summary></task-notification>',
    wait: false,
    origin: { kind: 'task-notification' },
  })

  expect(state.get('log')).toMatchObject([{ kind: 'task', text: 'Build finished (completed)' }])
})

test('/pet lists the notifications', async ($, on) => {
  mock.clock(on)
  watch(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))
  const pet = () =>
    $.command.run({
      command: 'pet',
      args: '',
      origin: { kind: 'composer' },
      presentation: { isFullscreen: false, columns: 120 },
    })

  expect((await pet()).text).toBe('Nothing yet. Mochi will tell you when things finish!')
  await $.turn.complete({ answer: 'ok', durationMs: 5_000, isAborted: false, turnId: 't', reason: 'answer' })
  expect((await pet()).text).toBe('✓ Done · 5s — ok')
})

test('nothing is drawn inside Claude anymore', async ($, on) => {
  mock.clock(on)
  const engineBand = h('Text', {}, 'the app band') as RenderElement
  on('ui.render', () => engineBand)

  const band = await $.ui.mount({
    plugin: 'pet-mod',
    surface: 'desktop',
    component: 'AbovePrompt',
    props: {
      hasSurvey: false,
      isWorking: false,
      maxRows: 20,
      bodyColumns: 100,
      scroll: { offset: 0, bodyRows: 19 },
      view: {},
    },
  })

  expect(JSON.stringify(await band.drawn())).toContain('the app band')
})

test('each chat reports to the floating Mochi through a small file', async ($, on) => {
  mock.clock(on, { now: 1_000 })
  watch(on)
  const { report } = computer(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))

  await $.turn.complete({ answer: 'ok', durationMs: 7_000, isAborted: false, turnId: 't', reason: 'answer' })

  expect(report()).toMatchObject({ title: 'garden', status: 'ready', updatedAt: 1_000 })
  expect(report().log).toMatchObject([{ kind: 'turn', text: 'Done', detail: 'ok', seconds: 7, at: 1_000 }])
})

test('a chat with no project folder is named after its first message', async ($, on) => {
  mock.clock(on, { now: 2_000 })
  watch(on)
  const { report } = computer(on, '/Users/test/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1')
  on('prompt.submit', (_, e) => ({ text: e.text }))

  await $.prompt.submit({ text: 'fix the login bug please', wait: false, origin: { kind: 'composer' } })

  expect(report()).toMatchObject({ title: '“fix the login bug please”', status: 'running' })
})

test('task summaries fall back to the first line', () => {
  expect(describeTask('<summary>Tests passed</summary><status>completed</status>')).toBe(
    'Tests passed (completed)',
  )
  expect(describeTask('Shell command "npm test" failed')).toBe('Shell command "npm test" failed')
  expect(describeTask('')).toBe('A background task finished')
})

test('a chat in the Claude app reports the link that opens it', async ($, on) => {
  mock.clock(on, { now: 3_000 })
  watch(on)
  const { report } = computer(on, '/Users/test/code/garden', { CLAUDE_CODE_HOST_SESSION_ID: 'local_abc-123' })
  on('turn.complete', (_, e) => ({ text: e.answer }))

  await $.turn.complete({ answer: 'ok', durationMs: 1_000, isAborted: false, turnId: 't', reason: 'answer' })

  expect(report().link).toBe('claude://code/continue?session=local_abc-123&source=mochi')
})

test('a terminal chat reports no link', async ($, on) => {
  mock.clock(on, { now: 3_000 })
  watch(on)
  const { report } = computer(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))

  await $.turn.complete({ answer: 'ok', durationMs: 1_000, isAborted: false, turnId: 't', reason: 'answer' })

  expect(report().link).toBeUndefined()
})

test('starting a chat wakes the floating Mochi in the background', async ($, on) => {
  const clock = mock.clock(on)
  watch(on)
  computer(on)
  const ran: string[][] = []
  on('process.run', (_, e) => {
    ran.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '' } } as never
  })
  on('command.register', () => ({ value: undefined }) as never)
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/Users/test/code/garden', surface: 'desktop', isInteractive: true })
  await clock.advance(1) // lets the background wake-up finish

  expect(ran).toEqual([['/usr/bin/open', '-g', '-b', 'local.claude-mods.mochi']])
})

test('if Mochi is not known by her id, she is opened from where she was built', async ($, on) => {
  const clock = mock.clock(on)
  watch(on)
  computer(on)
  const ran: string[][] = []
  on('process.run', (_, e) => {
    ran.push([...e.argv])
    return { value: { exitCode: ran.length === 1 ? 1 : 0, stdout: '', stderr: '' } } as never
  })
  on('command.register', () => ({ value: undefined }) as never)
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/Users/test/code/garden', surface: 'desktop', isInteractive: true })
  await clock.advance(1) // lets the background wake-up finish

  expect(ran[1]).toEqual(['/usr/bin/open', '-g', '/Users/test/Documents/Claude Mods/Mochi Desktop/Mochi.app'])
})

test('the summary is the first real sentence of the answer, without markdown', () => {
  expect(summarize('## Fixed it\n\nI fixed the **login** redirect bug. Also cleaned up tests.')).toBe('Fixed it')
  expect(summarize('I fixed the **login** redirect bug. Also cleaned up tests.')).toBe('I fixed the login redirect bug')
  expect(summarize('```ts\nconst a = 1\n```\n- Updated [the docs](https://x.y) for setup')).toBe('Updated the docs for setup')
  expect(summarize('')).toBe('')
  expect(summarize('x'.repeat(200)).length).toBeLessThanOrEqual(70)
})

test('what Claude waits for is said in a few words', () => {
  expect(describeAsk('Bash', { command: 'npm publish --tag next\necho done' })).toBe('Run: npm publish --tag next')
  expect(describeAsk('Edit', { file_path: '/Users/me/app/src/login.ts' })).toBe('Edit login.ts')
  expect(describeAsk('WebFetch', { url: 'https://example.com/page' })).toBe('Open example.com/page')
  expect(describeAsk('mcp__github__create_issue', {})).toBe('Use create_issue')
})

test('a chat waiting for your OK reports what for, and forgets it once approved', async ($, on) => {
  mock.clock(on, { now: 4_000 })
  watch(on)
  const { report } = computer(on)
  on('tool.check', () => ({ decision: 'ask' }))
  on('tool.call', () => ({ result: 'ok' }))

  await $.tool.check({ tool: 'Bash', input: { command: 'npm publish' } })
  expect(report()).toMatchObject({ status: 'needs-input', waiting: 'Run: npm publish' })

  await $.tool.call({ tool: 'Bash', input: { command: 'npm publish' } } as never)
  expect(report()).toMatchObject({ status: 'running', waiting: '' })
})

test('a finished turn reports a one-line summary of the answer', async ($, on) => {
  mock.clock(on, { now: 5_000 })
  watch(on)
  const { report } = computer(on)
  on('turn.complete', (_, e) => ({ text: e.answer }))

  await $.turn.complete({
    answer: 'I fixed the login redirect bug.\n\nHere is what changed:\n- moved the check',
    durationMs: 12_400,
    isAborted: false,
    turnId: 't',
    reason: 'answer',
  })

  expect(report().log).toMatchObject([{ text: 'Done', detail: 'I fixed the login redirect bug', seconds: 12 }])
})

test('a question for you reports the question', async ($, on) => {
  mock.clock(on, { now: 6_000 })
  watch(on)
  const { report } = computer(on)
  on('tool.call', (_, e) => {
    expect(report()).toMatchObject({ status: 'needs-input', waiting: 'Asks: Which database should I use?' })
    return { result: e.tool }
  })

  await $.tool.call({
    tool: 'AskUserQuestion',
    questions: [{ question: 'Which database should I use?', header: 'DB', options: [], multiSelect: false }],
  } as never)
})

test('live usage goes to Mochi when Claude reports it', async ($, on) => {
  mock.clock(on, { now: 7_000 })
  mock.env(on, { HOME: '/Users/test' })
  const files = new Map<string, string>()
  on('fs.write', (_, e) => {
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('session.measure', (_, e) => ({ changed: e.changed }))

  await $.session.measure({
    context: { windowTokens: 200_000 } as never,
    rateLimits: [
      { kind: 'five_hour', percentUsed: 23.5, resetsAt: '2026-10-09T12:00:00Z' },
      { kind: 'seven_day', percentUsed: 41, resetsAt: '2026-10-12T08:00:00Z' },
    ],
    changed: ['rateLimits'],
  })

  expect(JSON.parse(files.get('/Users/test/.claude/mochi/usage.json') ?? '{}')).toEqual({
    fiveHour: 23.5,
    fiveHourResetsAt: '2026-10-09T12:00:00Z',
    week: 41,
    weekResetsAt: '2026-10-12T08:00:00Z',
    at: 7_000,
  })
})
