import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import type { FilteredLogEvent, LogGroup, LogStream } from '@aws-sdk/client-cloudwatch-logs'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  Kv,
  Mono,
  Notices,
  Section,
  SortHeader,
  TabBar,
} from '../components/ServiceUi'
import { formatBytes, formatServiceDate } from '../lib/format'
import {
  filterLogEvents,
  getLogGroup,
  listLogStreams,
  retentionLabel,
} from '../lib/logs'

type DetailTab = 'streams' | 'events'

function streamHref(group: string, stream: string): string {
  return `/logs/log-groups/${encodeURIComponent(group)}/log-streams/${encodeURIComponent(stream)}`
}

export function LogsLogGroupDetailPage() {
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [tab, setTab] = useState<DetailTab>('streams')
  const [group, setGroup] = useState<LogGroup | null>(null)
  const [streams, setStreams] = useState<LogStream[]>([])
  const [streamFilter, setStreamFilter] = useState('')
  const [events, setEvents] = useState<FilteredLogEvent[]>([])
  const [pattern, setPattern] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refreshMeta = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const [g, s] = await Promise.all([
        getLogGroup(name),
        listLogStreams(name),
      ])
      setGroup(g ?? { logGroupName: name })
      setStreams(s)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  const refreshEvents = useCallback(
    async (filterPattern?: string) => {
      if (!name) return
      setBusy(true)
      setError(null)
      try {
        setEvents(
          await filterLogEvents({
            logGroupName: name,
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
    [name],
  )

  useEffect(() => {
    void refreshMeta()
  }, [refreshMeta])

  useEffect(() => {
    if (tab !== 'events') return
    void refreshEvents()
  }, [tab, refreshEvents])

  const filteredStreams = useMemo(() => {
    const q = streamFilter.trim().toLowerCase()
    if (!q) return streams
    return streams.filter((s) =>
      (s.logStreamName ?? '').toLowerCase().includes(q),
    )
  }, [streams, streamFilter])

  if (!name) {
    return <p className="aws-desc">Missing log group name.</p>
  }

  return (
    <>
      <div className="aws-toolbar">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1" style={{ margin: 0 }}>
            <ResourceLabel ids={[name, group?.arn]} detail>
              <Mono>{name}</Mono>
            </ResourceLabel>
          </h1>
          <div className="aws-subtitle-row">
            <span>Retention: {retentionLabel(group?.retentionInDays)}</span>
            <span>Stored: {formatBytes(group?.storedBytes ?? 0)}</span>
          </div>
        </div>
        <RefreshButton
          onClick={() => {
            void refreshMeta()
            if (tab === 'events') void refreshEvents(pattern)
          }}
        />
        <DeadButton>Actions ▾</DeadButton>
      </div>

      <p className="aws-desc">
        <Link to="/logs">Log groups</Link> › <Mono>{name}</Mono>
      </p>

      <Notices error={error} />

      <TabBar
        tabs={[
          ['streams', 'Log streams'],
          ['events', 'Search log group'],
        ]}
        active={tab}
        onChange={setTab}
      />

      {tab === 'streams' ? (
        <Section title="Log streams" spaced>
          <div className="aws-table-tools">
            <label className="aws-find">
              <span aria-hidden="true">⌕</span>
              <input
                type="search"
                placeholder="Filter log streams"
                aria-label="Filter log streams"
                value={streamFilter}
                onChange={(e) => setStreamFilter(e.target.value)}
              />
            </label>
          </div>
          <div className="aws-table-wrap">
            <table className="aws-table" data-testid="log-streams-table">
              <thead>
                <tr>
                  <SortHeader>Log stream</SortHeader>
                  <SortHeader>Last event time</SortHeader>
                  <SortHeader>Creation time</SortHeader>
                </tr>
              </thead>
              <tbody>
                {filteredStreams.length === 0 ? (
                  <EmptyRow
                    colSpan={3}
                    loading={loading}
                    loadingText="Loading log streams…"
                    title="No log streams"
                    text="This log group has no streams yet."
                  />
                ) : (
                  filteredStreams.map((s) => {
                    const streamName = s.logStreamName ?? ''
                    return (
                      <tr key={streamName}>
                        <td>
                          <Mono>
                            <Link to={streamHref(name, streamName)}>
                              {streamName}
                            </Link>
                          </Mono>
                        </td>
                        <td>
                          {s.lastEventTimestamp
                            ? formatServiceDate(new Date(s.lastEventTimestamp))
                            : '—'}
                        </td>
                        <td>
                          {s.creationTime
                            ? formatServiceDate(new Date(s.creationTime))
                            : '—'}
                        </td>
                      </tr>
                    )
                  })
                )}
              </tbody>
            </table>
          </div>
        </Section>
      ) : (
        <Section title="Search log group" spaced>
          <p className="aws-desc">
            FilterLogEvents across streams (interleaved). Pattern syntax is
            what LocalEmu supports.
          </p>
          <div className="aws-toolbar" style={{ flexWrap: 'wrap', gap: 8 }}>
            <label className="aws-find" style={{ flex: 1, minWidth: 220, maxWidth: 480 }}>
              <input
                type="search"
                placeholder="Filter pattern"
                aria-label="Filter pattern"
                value={pattern}
                onChange={(e) => setPattern(e.target.value)}
                data-testid="logs-filter-pattern"
              />
            </label>
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy}
              onClick={() => void refreshEvents(pattern)}
              data-testid="logs-search-events"
            >
              {busy ? 'Loading…' : 'Search'}
            </button>
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy}
              onClick={() => void refreshEvents(pattern)}
              data-testid="logs-tail-events"
            >
              Tail
            </button>
          </div>
          <div className="aws-table-wrap" style={{ marginTop: 12 }}>
            <table className="aws-table" data-testid="log-events-table">
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
                    text="No events match this filter yet."
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
      )}

      <Section title="Overview" spaced>
        <Kv
          rows={[
            ['Log group', <Mono key="n">{name}</Mono>],
            ['ARN', <Mono key="a">{group?.arn ?? '—'}</Mono>],
            ['Retention', retentionLabel(group?.retentionInDays)],
            ['Stored bytes', formatBytes(group?.storedBytes ?? 0)],
            [
              'Metric filters',
              String(group?.metricFilterCount ?? 0),
            ],
          ]}
        />
      </Section>

      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to="/logs">Back to log groups</Link>
      </p>
    </>
  )
}
