import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { parse } from 'yaml'

export type LabelEntry = {
  match: string
  label: string
  note?: string
  link?: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function resolveLabelsPath(raw: string): string {
  if (raw === '~') return os.homedir()
  if (raw.startsWith('~/')) return path.join(os.homedir(), raw.slice(2))
  return raw
}

function optionalText(
  value: unknown,
  match: string,
  field: string,
): string | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'string') {
    throw new Error(`${match}: ${field} must be a string`)
  }
  const trimmed = value.trim()
  return trimmed === '' ? undefined : trimmed
}

function optionalLink(value: unknown, match: string): string | undefined {
  const link = optionalText(value, match, 'link')
  if (link === undefined) return undefined
  let url: URL
  try {
    url = new URL(link)
  } catch {
    throw new Error(`${match}: link must be an http(s) URL`)
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`${match}: link must be an http(s) URL`)
  }
  return link
}

export function parseLabelsDocument(value: unknown): LabelEntry[] {
  if (value === undefined || value === null) return []
  if (!isRecord(value)) {
    throw new Error('labels file must be a mapping of id or ARN to label')
  }
  const entries: LabelEntry[] = []
  for (const [match, body] of Object.entries(value)) {
    if (match.trim() === '') throw new Error('label key is empty')
    if (!isRecord(body)) {
      throw new Error(`${match}: expected label, optional note, optional link`)
    }
    const label = optionalText(body.label, match, 'label')
    if (label === undefined) throw new Error(`${match}: label is required`)
    const entry: LabelEntry = { match, label }
    const note = optionalText(body.note, match, 'note')
    if (note !== undefined) entry.note = note
    const link = optionalLink(body.link, match)
    if (link !== undefined) entry.link = link
    entries.push(entry)
  }
  return entries
}

export function loadLabelEntries(): LabelEntry[] {
  const raw = process.env.STACKWRANGLER_LABELS || process.env.AWSBOX_LABELS
  if (raw === undefined || raw.trim() === '') return []
  const filePath = resolveLabelsPath(raw.trim())
  if (!fs.existsSync(filePath)) return []
  const stat = fs.statSync(filePath)
  if (!stat.isFile()) throw new Error('STACKWRANGLER_LABELS is not a file')
  const text = fs.readFileSync(filePath, 'utf8')
  const parsed: unknown = parse(text)
  return parseLabelsDocument(parsed)
}
