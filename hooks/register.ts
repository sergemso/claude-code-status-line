import type { Register } from 'claude-code'
import { splitArgs } from './args'

// Zero-model-turn settings commands: each runs ~/.claude/statusline/config.sh <subcommand> <args>
// and prints the output. They are answered here, so no model turn is spent.
// (Module command names allow letters, digits, _ and - only, hence "statusline-model".)
const COMMANDS: Record<string, { sub: string; description: string; hint?: string }> = {
  'statusline-show':       { sub: 'show',       description: 'Show the status line settings and where each value comes from' },
  'statusline-model':      { sub: 'model',      description: 'Base model for the price multiplier', hint: '<name | list>' },
  'statusline-sections':   { sub: 'sections',   description: 'Show/hide sections: model context cache stats resets', hint: '<show|hide|only NAME… | all>' },
  'statusline-resets':     { sub: 'resets',     description: 'Which reset windows to show', hint: '<5h,7d,spend | all | none>' },
  'statusline-thresholds': { sub: 'thresholds', description: 'Yellow/red breakpoints', hint: '<context|resets|cache> <warn> <crit>' },
  'statusline-width':      { sub: 'width',      description: 'Terminal width to fit the line into', hint: '<columns | auto>' },
  'statusline-reset':      { sub: 'reset',      description: 'Drop saved settings (all, or the KEYs you name)', hint: '[KEY…]' },
}

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    for (const [name, { description, hint }] of Object.entries(COMMANDS)) {
      await $.command.register({ name, description, ...(hint ? { argumentHint: hint } : {}) })
    }
    return next(e)
  })

  for (const [name, { sub }] of Object.entries(COMMANDS)) {
    on('command.run', { command: name }, async ($, e) => {
      const argv = [
        'bash', '-c',
        'exec bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/config.sh" "$@"',
        'statusline',
        sub, ...splitArgs(e.args),
      ]
      try {
        const r = await $.process.run(argv)
        return { text: `${r.stdout}${r.stderr}`.trim() || '(no output)' }
      } catch (err) {
        return { text: `${name}: could not run config.sh: ${err instanceof Error ? err.message : String(err)}` }
      }
    })
  }
}
