import { useCallback, useEffect, useState } from 'react'
import type { FilteredLogEvent, LogGroup } from '@aws-sdk/client-cloudwatch-logs'
import { filterLogEvents, listLogGroups } from '../lib/logs'

export function LogsPage() {
  const [groups, setGroups] = useState<LogGroup[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [events, setEvents] = useState<FilteredLogEvent[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)

  const refreshGroups = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listLogGroups()
      setGroups(list)
      setSelected((prev) => prev ?? list[0]?.logGroupName ?? null)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  const refreshEvents = useCallback(async (group: string) => {
    setBusy(true)
    setError(null)
    try {
      setEvents(await filterLogEvents(group))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setEvents([])
    } finally {
      setBusy(false)
    }
  }, [])

  useEffect(() => {
    void refreshGroups()
  }, [refreshGroups])

  useEffect(() => {
    if (selected) {
      void refreshEvents(selected)
    } else {
      setEvents([])
    }
  }, [selected, refreshEvents])

  return (
    <div>
      <h1>Log groups</h1>
      <p className="page-lead">
        CloudWatch Logs on the local emulator. Invoke a Lambda first to create{' '}
        <code>/aws/lambda/…</code> groups, then tail events here.
      </p>

      {error ? <div className="error-banner">{error}</div> : null}

      <div className="toolbar toolbar-stack">
        <h3>Log groups ({groups.length})</h3>
        <div className="toolbar-actions">
          <button
            type="button"
            className="btn"
            onClick={() => void refreshGroups()}
          >
            Refresh groups
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={!selected || busy}
            onClick={() => selected && void refreshEvents(selected)}
          >
            {busy ? 'Loading…' : 'Tail events'}
          </button>
        </div>
      </div>

      {loading ? (
        <p>Loading…</p>
      ) : groups.length === 0 ? (
        <p className="empty-state">No log groups</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th />
              <th>Log group</th>
              <th>Stored bytes</th>
            </tr>
          </thead>
          <tbody>
            {groups.map((g) => {
              const name = g.logGroupName ?? ''
              return (
                <tr
                  key={name}
                  className={selected === name ? 'row-selected' : undefined}
                >
                  <td>
                    <input
                      type="radio"
                      name="lg"
                      checked={selected === name}
                      aria-label={`Select ${name}`}
                      onChange={() => setSelected(name)}
                    />
                  </td>
                  <td>
                    <code>{name}</code>
                  </td>
                  <td>{g.storedBytes ?? 0}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}

      {selected ? (
        <div className="invoke-panel">
          <h3>Events — {selected}</h3>
          {events.length === 0 ? (
            <p className="empty-state">No events yet</p>
          ) : (
            <pre className="lab-detail log-tail">
              {events
                .map((e) => {
                  const t = e.timestamp
                    ? new Date(e.timestamp).toISOString()
                    : ''
                  return `${t}  ${e.message ?? ''}`
                })
                .join('')}
            </pre>
          )}
        </div>
      ) : null}
    </div>
  )
}
