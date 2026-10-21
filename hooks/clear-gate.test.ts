import { expect, mock, test } from 'claude-code/testing'

const AUTO = 'Blueprint approved.\nauto: clear gate stage-2-to-3 — type /clear, then /mi-continue'
const MANUAL =
  'Blueprint for `x` approved. **Recommended:** type `/clear`, then `/mi-continue` to enter stage 3 with a fresh main context.'
// What a turn really ended on (2026-10-20): the answer restated the gate line.
const RESTATED = '`game-project` is complete and archived.\n\nNext step: type `/clear`, then `/mi-continue` to start `table-ui`.'
const QUOTED = 'The gate says: type /clear, then /mi-continue.\n' + 'Here is more explanation. '.repeat(80)
const CONTINUE = 'millwright-inspector-development-machine:mi-continue'

// Records every command the hook runs.
function rig(on: any) {
  const ran: string[] = []
  const clock = mock.clock(on)
  on('turn.complete', (_: unknown, e: any) => ({ text: e.answer }))
  on('command.run', (_: unknown, e: any) => {
    ran.push(e.command)
    return { text: '' }
  })
  return { ran, clock }
}

for (const [name, answer, expected] of [
  ['auto gate clears, then continues', AUTO, ['clear', CONTINUE]],
  ['manual gate clears, then continues', MANUAL, ['clear', CONTINUE]],
  ['a restated gate clears, then continues', RESTATED, ['clear', CONTINUE]],
  ['a quoted gate in a long answer does nothing', QUOTED, []],
  ['plain text does nothing', 'All done.', []],
] as const) {
  test(name, async ($, on) => {
    const { ran, clock } = rig(on)
    await $.turn.complete({ answer, durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
    await clock.advance(1000)
    expect(ran).toEqual(expected)
  })
}

test('a subagent turn never clears', async ($, on) => {
  const { ran, clock } = rig(on)
  await $.turn.complete({ answer: AUTO, durationMs: 1, isAborted: false, turnId: 't2', reason: 'answer', agentId: 'a1' })
  await clock.advance(1000)
  expect(ran).toEqual([])
})

test('auto_clear off does nothing', { options: { auto_clear: false } }, async ($, on) => {
  const { ran, clock } = rig(on)
  await $.turn.complete({ answer: AUTO, durationMs: 1, isAborted: false, turnId: 't3', reason: 'answer' })
  await clock.advance(1000)
  expect(ran).toEqual([])
})
