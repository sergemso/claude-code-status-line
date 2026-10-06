---
description: Change status line settings: base model, sections, reset windows, color breakpoints (no args = guided)
disable-model-invocation: true
allowed-tools: Bash, AskUserQuestion
---

Settings tool: `bash "${CLAUDE_PLUGIN_ROOT}/bin/config.sh"`. Run it with Bash, quoting each argument. Report its output tersely.

**If `$ARGUMENTS` is not empty:** run `config.sh $ARGUMENTS`. On an error, show it and stop.

**If `$ARGUMENTS` is empty:** run `config.sh show`, then guide the user with AskUserQuestion, one question at a time, applying each answer with the matching `config.sh` command before asking the next:

1. "What do you want to change?" (options: Sections, Base model, Reset windows, Color breakpoints). Stop after applying one change unless they pick another.
2. Sections: multi-select which to hide (`config.sh sections hide ...`); if more than four are relevant, ask in two rounds. Names: model context cache stats resets (stats = cache hit rate, shown inside cache). Offer "Show all" via Other.
3. Base model: run `config.sh model list`, offer the 3-4 most relevant models (the current base, the user's current model, cheapest, priciest); anything else via Other. Apply with `config.sh model NAME`.
4. Reset windows: options 5h+7d (default), 5h+7d+spend, all the API sends, none; custom via Other. Apply with `config.sh resets LIST`.
5. Color breakpoints: ask which (context, reset windows, cache), then WARN and CRIT via Other with the current values as the suggested options. Apply with `config.sh thresholds KIND WARN CRIT`.

Finish with `config.sh show`. Settings apply on the next status line refresh. Tell the user that scripting it directly costs no tokens: `! bash ~/.claude/statusline/config.sh <command>` (`config.sh help` lists them).
