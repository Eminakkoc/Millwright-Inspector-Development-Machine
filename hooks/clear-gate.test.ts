import { expect, mock, test } from 'claude-code/testing'

const AUTO = 'Blueprint approved.\nauto: clear gate stage-2-to-3 — type /clear, then /mi-continue'
const MANUAL =
  'Blueprint for `x` approved. **Recommended:** type `/clear`, then `/mi-continue` to enter stage 3 with a fresh main context.'
// What a turn really ended on (2026-10-20): the gate line was in a Bash result
// and the answer restated it, so the text alone can't say auto from manual.
const RESTATED = '`game-project` is complete and archived.\n\nNext step: type `/clear`, then `/mi-continue` to start `table-ui`.'
const QUOTED = 'The gate says: type /clear, then /mi-continue.\n' + 'Here is more explanation. '.repeat(80)
const CONTINUE = 'millwright-inspector-development-machine:mi-continue'

// Records every command the hook runs, and answers `auto.sh is-on` with
// `autoExit` (0 = auto mode on), or fails to start it when `autoExit` is null.
function rig(on: any, autoExit: number | null) {
  const ran: string[] = []
  const checks: string[][] = []
  const clock = mock.clock(on)
  on('turn.complete', (_: unknown, e: any) => ({ text: e.answer }))
  on('command.run', (_: unknown, e: any) => {
    ran.push(e.command)
    return { text: '' }
  })
  on('process.run', (_: unknown, e: any) => {
    checks.push([...e.argv])
    if (autoExit === null) return { deny: 'bash not found' }
    return { value: { exitCode: autoExit, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  return { ran, checks, clock }
}

for (const [name, answer, autoExit, expected] of [
  ['auto gate clears, then continues', AUTO, 1, ['clear', CONTINUE]],
  ['manual gate only clears', MANUAL, 1, ['clear']],
  ['a restated gate in auto mode clears, then continues', RESTATED, 0, ['clear', CONTINUE]],
  ['a restated gate in manual mode only clears', RESTATED, 1, ['clear']],
  ['auto.sh failing to start reads as manual', RESTATED, null, ['clear']],
  ['a quoted gate in a long answer does nothing', QUOTED, 0, []],
  ['plain text does nothing', 'All done.', 0, []],
] as const) {
  test(name, async ($, on) => {
    const { ran, clock } = rig(on, autoExit)
    await $.turn.complete({ answer, durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
    await clock.advance(1000)
    expect(ran).toEqual(expected)
  })
}

test('auto mode is read from scripts/auto.sh is-on', async ($, on) => {
  const { checks, clock } = rig(on, 0)
  await $.turn.complete({ answer: RESTATED, durationMs: 1, isAborted: false, turnId: 't4', reason: 'answer' })
  await clock.advance(1000)
  expect(checks.length).toBe(1)
  expect(checks[0][0]).toBe('bash')
  expect(checks[0][1].endsWith('/scripts/auto.sh')).toBe(true)
  expect(checks[0][2]).toBe('is-on')
})

test('the auto gate line needs no auto.sh check', async ($, on) => {
  const { checks, clock } = rig(on, 1)
  await $.turn.complete({ answer: AUTO, durationMs: 1, isAborted: false, turnId: 't5', reason: 'answer' })
  await clock.advance(1000)
  expect(checks).toEqual([])
})

test('a subagent turn never clears', async ($, on) => {
  const { ran, clock } = rig(on, 0)
  await $.turn.complete({ answer: AUTO, durationMs: 1, isAborted: false, turnId: 't2', reason: 'answer', agentId: 'a1' })
  await clock.advance(1000)
  expect(ran).toEqual([])
})

test('auto_clear off does nothing', { options: { auto_clear: false } }, async ($, on) => {
  const { ran, clock } = rig(on, 0)
  await $.turn.complete({ answer: AUTO, durationMs: 1, isAborted: false, turnId: 't3', reason: 'answer' })
  await clock.advance(1000)
  expect(ran).toEqual([])
})
