import { useCallback, useEffect, useMemo, useState } from 'react'
import { RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  ListCard,
  Notices,
} from '../components/ServiceUi'
import {
  listApiCalls,
  type ApiCallFilters,
  type ApiCallRecord,
} from '../lib/apiCallLog'

function resultLabel(rec: ApiCallRecord): string {
  if (rec.result === 'allowed') return 'allowed'
  if (rec.reason) return `denied — ${rec.reason}`
  return 'denied'
}

export function ApiCallLogPage() {
  const [calls, setCalls] = useState<ApiCallRecord[]>([])
  const [workload, setWorkload] = useState('')
  const [service, setService] = useState('')
  const [action, setAction] = useState('')
  const [result, setResult] = useState('')
  const [since, setSince] = useState('')
  const [filter, setFilter] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async (filters: ApiCallFilters) => {
    setLoading(true)
    setError(null)
    try {
      const list = await listApiCalls(filters)
      setCalls(list)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh({})
  }, [refresh])

  function applyFilters() {
    void refresh({
      workload: workload.trim() || undefined,
      service: service.trim() || undefined,
      action: action.trim() || undefined,
      result: result.trim() || undefined,
      since: since.trim() || undefined,
    })
  }

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return calls
    return calls.filter((rec) => {
      const hay = [
        rec.time,
        rec.workload,
        rec.caller,
        rec.service,
        rec.action,
        rec.resources.join(' '),
        resultLabel(rec),
        rec.request_id ?? '',
      ]
        .join(' ')
        .toLowerCase()
      return hay.includes(q)
    })
  }, [calls, filter])

  return (
    <ListCard
      title="API call log"
      desc="Local CloudTrail-lite: every AWS API call a workload made (Lambda, ECS task, CLI profile), with allow/deny result. Bodies are not recorded."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <label className="aws-find" style={{ maxWidth: 160 }}>
            <input
              type="search"
              placeholder="Workload"
              aria-label="Filter by workload"
              value={workload}
              onChange={(e) => setWorkload(e.target.value)}
              data-testid="filter-workload"
            />
          </label>
          <label className="aws-find" style={{ maxWidth: 140 }}>
            <input
              type="search"
              placeholder="Service"
              aria-label="Filter by service"
              value={service}
              onChange={(e) => setService(e.target.value)}
              data-testid="filter-service"
            />
          </label>
          <label className="aws-find" style={{ maxWidth: 180 }}>
            <input
              type="search"
              placeholder="Action"
              aria-label="Filter by action"
              value={action}
              onChange={(e) => setAction(e.target.value)}
              data-testid="filter-action"
            />
          </label>
          <label>
            <select
              aria-label="Filter by result"
              value={result}
              onChange={(e) => setResult(e.target.value)}
              style={{ height: 32 }}
              data-testid="filter-result"
            >
              <option value="">Result: any</option>
              <option value="allowed">allowed</option>
              <option value="denied">denied</option>
            </select>
          </label>
          <label className="aws-find" style={{ maxWidth: 200 }}>
            <input
              type="search"
              placeholder="Since (ISO time)"
              aria-label="Filter since time"
              value={since}
              onChange={(e) => setSince(e.target.value)}
              data-testid="filter-since"
            />
          </label>
          <button
            type="button"
            className="btn btn-normal"
            onClick={applyFilters}
            data-testid="apply-filters"
          >
            Apply filters
          </button>
          <RefreshButton onClick={() => applyFilters()} />
        </>
      }
      placeholder="Find in table"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="api-call-log-table">
        <thead>
          <tr>
            <th scope="col">Time</th>
            <th scope="col">Workload</th>
            <th scope="col">Principal</th>
            <th scope="col">Service</th>
            <th scope="col">Action</th>
            <th scope="col">Resource(s)</th>
            <th scope="col">Result</th>
            <th scope="col">Request ID</th>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={8}
              loading={loading}
              loadingText="Loading API calls…"
              title="No API calls"
              text="Invoke a Lambda, run an ECS task, or use a CLI profile against LocalEmu to populate this log."
            />
          ) : (
            filtered.map((rec) => (
              <tr key={`${rec.request_id ?? ''}-${rec.time}-${rec.action}`}>
                <td>
                  <code className="aws-mono">{rec.time}</code>
                </td>
                <td>
                  <code className="aws-mono">{rec.workload}</code>
                </td>
                <td>
                  <code className="aws-mono">{rec.caller}</code>
                </td>
                <td>{rec.service}</td>
                <td>
                  <code className="aws-mono">{rec.action}</code>
                </td>
                <td>
                  <code className="aws-mono">
                    {rec.resources.length ? rec.resources.join(', ') : '—'}
                  </code>
                </td>
                <td>{resultLabel(rec)}</td>
                <td>
                  <code className="aws-mono">{rec.request_id ?? '—'}</code>
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
