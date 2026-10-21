import type { Register } from 'claude-code'

// A clear gate ends a turn with "type `/clear`, then `/mi-continue`" (manual:
// "**Recommended:** type ..."; auto mode: "auto: clear gate <gate> — type ...").
// Claude Code does not run built-in commands for model text, so this hook runs
// /clear itself when the turn ends, then /mi-continue, auto mode or not.
const GATE = /type\s+`?\/clear`?\s*,?\s*then\s+`?\/mi-continue`?/i
const CONTINUE = 'millwright-inspector-development-machine:mi-continue'

// Only the tail counts: an answer that quotes a gate and then goes on is not one.
const TAIL = 1200

export const register: Register = (on, options) => {
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return done
    if (options.auto_clear === false) return done

    const tail = e.answer.slice(-TAIL)
    if (!GATE.test(tail)) return done

    // $.command.run is refused inside a hook the turn waits on, so run it after.
    $.clock.after(500, async () => {
      await $.command.run({ command: 'clear', args: '' })
      await $.command.run({ command: CONTINUE, args: '' })
    })
    return done
  }).catch(($, e, next) => next(e))
}
