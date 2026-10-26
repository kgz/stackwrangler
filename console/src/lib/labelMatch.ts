export type LabelEntry = {
  match: string
  label: string
  note?: string
  link?: string
}

function escapeRegExpChar(ch: string): string {
  if ('\\^$+?.()|[]{}'.includes(ch)) return `\\${ch}`
  return ch
}

export function globMatch(pattern: string, value: string): boolean {
  let source = '^'
  for (const ch of pattern) {
    if (ch === '*') source += '.*'
    else if (ch === '?') source += '.'
    else source += escapeRegExpChar(ch)
  }
  source += '$'
  return new RegExp(source).test(value)
}

export function matchLabel(
  entries: LabelEntry[],
  id: string,
): LabelEntry | null {
  if (id === '') return null
  for (const entry of entries) {
    if (globMatch(entry.match, id)) return entry
  }
  return null
}

export function matchAny(
  entries: LabelEntry[],
  ids: Array<string | undefined>,
): LabelEntry | null {
  for (const id of ids) {
    if (!id) continue
    const hit = matchLabel(entries, id)
    if (hit) return hit
  }
  return null
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function parseLabelEntries(value: unknown): LabelEntry[] {
  if (!isRecord(value) || !Array.isArray(value.entries)) return []
  const entries: LabelEntry[] = []
  for (const item of value.entries) {
    if (!isRecord(item)) continue
    if (typeof item.match !== 'string' || typeof item.label !== 'string') continue
    const entry: LabelEntry = { match: item.match, label: item.label }
    if (typeof item.note === 'string' && item.note !== '') entry.note = item.note
    if (typeof item.link === 'string' && item.link !== '') entry.link = item.link
    entries.push(entry)
  }
  return entries
}

export async function fetchLabelEntries(): Promise<LabelEntry[]> {
  try {
    const res = await fetch('/_awsl/labels', { cache: 'no-store' })
    if (!res.ok) return []
    const body: unknown = await res.json()
    return parseLabelEntries(body)
  } catch {
    return []
  }
}
