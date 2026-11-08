export type ApiCallRecord = {
  time: string
  caller: string
  workload: string
  service: string
  action: string
  resources: string[]
  result: string
  reason: string | null
  request_id: string | null
}

export type ApiCallFilters = {
  workload?: string
  service?: string
  action?: string
  result?: string
  since?: string
}

function callsUrl(filters: ApiCallFilters): string {
  const params = new URLSearchParams()
  if (filters.workload) params.set('workload', filters.workload)
  if (filters.service) params.set('service', filters.service)
  if (filters.action) params.set('action', filters.action)
  if (filters.result) params.set('result', filters.result)
  if (filters.since) params.set('since', filters.since)
  const qs = params.toString()
  return qs ? `/_awsl/calls?${qs}` : '/_awsl/calls'
}

function isCallRecord(value: unknown): value is ApiCallRecord {
  if (typeof value !== 'object' || value === null) return false
  const rec = value as Record<string, unknown>
  return (
    typeof rec.time === 'string' &&
    typeof rec.caller === 'string' &&
    typeof rec.workload === 'string' &&
    typeof rec.service === 'string' &&
    typeof rec.action === 'string' &&
    Array.isArray(rec.resources) &&
    typeof rec.result === 'string'
  )
}

export async function listApiCalls(
  filters: ApiCallFilters = {},
): Promise<ApiCallRecord[]> {
  const res = await fetch(callsUrl(filters), { cache: 'no-store' })
  if (!res.ok) {
    throw new Error(`GET /_awsl/calls failed (${res.status})`)
  }
  const body: unknown = await res.json()
  if (typeof body !== 'object' || body === null) {
    throw new Error('GET /_awsl/calls returned unexpected JSON')
  }
  const calls = (body as Record<string, unknown>).calls
  if (!Array.isArray(calls)) {
    throw new Error('GET /_awsl/calls missing calls array')
  }
  return calls.filter(isCallRecord)
}
