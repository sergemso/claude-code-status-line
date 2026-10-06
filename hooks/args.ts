// Split a command line into words, honouring single and double quotes.
export function splitArgs(s: string): string[] {
  const out: string[] = []
  let cur = ''
  let quote = ''
  let has = false
  for (const ch of s) {
    if (quote) {
      if (ch === quote) quote = ''
      else cur += ch
    } else if (ch === '"' || ch === "'") {
      quote = ch
      has = true
    } else if (/\s/.test(ch)) {
      if (has || cur) out.push(cur)
      cur = ''
      has = false
    } else {
      cur += ch
    }
  }
  if (has || cur) out.push(cur)
  return out
}
