import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import type { FilteredLogEvent } from '@aws-sdk/client-cloudwatch-logs'
import { RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  Mono,
  Notices,
  Section,
  SortHeader,
} from '../components/ServiceUi'
import { filterLogEvents } from '../lib/logs'

export function LogsLogStreamEventsPage() {
  const { name: rawName, stream: rawStream } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const stream = rawStream ? decodeURIComponent(rawStream) : ''
  const [events, setEvents] = useState<FilteredLogEvent[]>([])
  const [pattern, setPattern] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(
    async (filterPattern?: string) => {
      if (!name || !stream) return
      setBusy(true)
      setError(null)
      try {
        setEvents(
          await filterLogEvents({
            logGroupName: name,
            logStreamNames: [stream],
            filterPattern,
            limit: 100,
          }),
        )
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
        setEvents([])
      } finally {
        setBusy(false)
      }
    },
    [name, stream],
  )

  useEffect(() => {
    void refresh()
  }, [refresh])

  if (!name || !stream) {
    return <p className="aws-desc">Missing log group or stream name.</p>
  }

  const groupHref = `/logs/log-groups/${encodeURIComponent(name)}`

  return (
    <>
      <div className="aws-toolbar">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1" style={{ margin: 0 }}>
            <Mono>{stream}</Mono>
          </h1>
          <div className="aws-subtitle-row">
            <span>
              Log group: <Mono>{name}</Mono>
            </span>
          </div>
        </div>
        <RefreshButton onClick={() => void refresh(pattern)} />
      </div>

      <p className="aws-desc">
        <Link to="/logs">Log groups</Link> ›{' '}
        <Link to={groupHref}>
          <Mono>{name}</Mono>
        </Link>{' '}
        › <Mono>{stream}</Mono>
      </p>

      <Notices error={error} />

      <Section title="Log events">
        <div className="aws-toolbar" style={{ flexWrap: 'wrap', gap: 8 }}>
          <label
            className="aws-find"
            style={{ flex: 1, minWidth: 220, maxWidth: 480 }}
          >
            <input
              type="search"
              placeholder="Filter pattern"
              aria-label="Filter pattern"
              value={pattern}
              onChange={(e) => setPattern(e.target.value)}
              data-testid="logs-stream-filter-pattern"
            />
          </label>
          <button
            type="button"
            className="btn btn-normal"
            disabled={busy}
            onClick={() => void refresh(pattern)}
            data-testid="logs-stream-search"
          >
            {busy ? 'Loading…' : 'Search'}
          </button>
          <button
            type="button"
            className="btn btn-normal"
            disabled={busy}
            onClick={() => void refresh(pattern)}
            data-testid="logs-stream-tail"
          >
            Tail
          </button>
        </div>
        <div className="aws-table-wrap" style={{ marginTop: 12 }}>
          <table className="aws-table" data-testid="log-stream-events-table">
            <thead>
              <tr>
                <SortHeader>Timestamp</SortHeader>
                <SortHeader>Message</SortHeader>
              </tr>
            </thead>
            <tbody>
              {events.length === 0 ? (
                <EmptyRow
                  colSpan={2}
                  loading={busy}
                  loadingText="Loading events…"
                  title="No events"
                  text="No events in this stream yet."
                />
              ) : (
                events.map((e, i) => (
                  <tr key={`${e.eventId ?? i}-${e.timestamp ?? i}`}>
                    <td>
                      <Mono>
                        {e.timestamp
                          ? new Date(e.timestamp).toISOString()
                          : '—'}
                      </Mono>
                    </td>
                    <td>
                      <Mono>{e.message ?? ''}</Mono>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </Section>

      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to={groupHref}>Back to log group</Link>
      </p>
    </>
  )
}
