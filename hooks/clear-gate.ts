import type { Register } from 'claude-code'

// A clear gate ends a turn with "type `/clear`, then `/mi-continue`" (manual:
// "**Recommended:** type ..."; auto mode: "auto: clear gate <gate> — type ...").
// Claude Code does not run built-in commands for model text, so this hook runs
// /clear itself when the turn ends. Auto mode also sends /mi-continue, as the
// gate line says; a manual gate only clears, and the inspector types /mi-continue.
const GATE = /type\s+`?\/clear`?\s*,?\s*then\s+`?\/mi-continue`?/i
const AUTO_GATE = /^auto: clear gate [\w-]+ — type\s+`?\/clear/m
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
      // The auto gate line comes out of a Bash call, and the answer often
      // restates it without its `auto:` prefix ("Next step: type `/clear`, then
      // `/mi-continue` …"), so the workflow's own state decides: `auto.sh is-on`,
      // run from the session's folder as the commands run it. A failure reads
      // as off, and the gate then only clears, as a manual one does.
      let isAuto = AUTO_GATE.test(tail)
      if (!isAuto) {
        const env: Record<string, string> = { CLAUDE_PLUGIN_ROOT: $.plugin.root }
        if (typeof options.data_root === 'string' && options.data_root) {
          env.CLAUDE_PLUGIN_USER_CONFIG_data_root = options.data_root
        }
        isAuto = await $.process
          .run(['bash', `${$.plugin.root}/scripts/auto.sh`, 'is-on'], { env, timeoutMs: 10_000 })
          .then(r => r.exitCode === 0, () => false)
      }
      await $.command.run({ command: 'clear', args: '' })
      if (isAuto) await $.command.run({ command: CONTINUE, args: '' })
    })
    return done
  }).catch(($, e, next) => next(e))
}
