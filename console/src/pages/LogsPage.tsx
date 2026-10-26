import { useCallback, useEffect, useMemo, useState } from 'react'
import type { FilteredLogEvent, LogGroup } from '@aws-sdk/client-cloudwatch-logs'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DeadLink,
  EmptyRow,
  FilterHeader,
  ListCard,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatBytes } from '../lib/format'
import { filterLogEvents, listLogGroups } from '../lib/logs'

function retentionLabel(days: number | undefined): string {
  if (!days) return 'Never expire'
  return days === 1 ? '1 day' : `${days} days`
}

export function LogsPage() {
  const [groups, setGroups] = useState<LogGroup[]>([])
  const [filter, setFilter] = useState('')
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
      setSelected((prev) =>
        prev && list.some((g) => g.logGroupName === prev) ? prev : null,
      )
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

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return groups
    return groups.filter((g) => (g.logGroupName ?? '').toLowerCase().includes(q))
  }, [groups, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <>
      <ListCard
        title="Log groups"
        desc="A log group is a group of log streams that share the same retention, monitoring, and access control settings."
        notices={<Notices error={error} />}
        toolbar={
          <>
            <RefreshButton onClick={() => void refreshGroups()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selected || busy}
              title={selected ? undefined : 'Select a row'}
              onClick={() => selected && void refreshEvents(selected)}
            >
              {busy ? 'Loading…' : 'Tail events'}
            </button>
            <DeadButton>Actions ▾</DeadButton>
            <div className="spacer" />
            <DeadButton variant="primary">Create log group</DeadButton>
          </>
        }
        placeholder="Filter log groups"
        filter={filter}
        onFilter={setFilter}
      >
        <table className="aws-table" data-testid="log-groups-table">
          <thead>
            <tr>
              <SelectHeader />
              <SortHeader>Log group</SortHeader>
              <FilterHeader>Retention</FilterHeader>
              <SortHeader>Stored bytes</SortHeader>
              <FilterHeader>Metric filters</FilterHeader>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 ? (
              <EmptyRow
                colSpan={5}
                loading={loading}
                loadingText="Loading log groups…"
                title="No log groups"
                text="No log groups match this region yet."
              />
            ) : (
              filtered.map((g) => {
                const name = g.logGroupName ?? ''
                const isSelected = selected === name
                return (
                  <tr
                    key={name}
                    className={`selectable${isSelected ? ' selected' : ''}`}
                    onClick={() => toggle(name)}
                  >
                    <SelectCell
                      name="selected-lg"
                      id={name}
                      selected={isSelected}
                      onToggle={toggle}
                    />
                    <td>
                      <ResourceLabel ids={[name, g.arn]} detail={isSelected}>
                        <Mono>
                          <DeadLink>{name}</DeadLink>
                        </Mono>
                      </ResourceLabel>
                    </td>
                    <td>{retentionLabel(g.retentionInDays)}</td>
                    <td>{formatBytes(g.storedBytes ?? 0)}</td>
                    <td>{g.metricFilterCount ?? 0}</td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </ListCard>

      {selected ? (
        <section className="aws-card" style={{ marginTop: 16 }}>
          <div className="aws-card-body">
            <h2 className="aws-section-title">Events — {selected}</h2>
            {events.length === 0 ? (
              <p className="aws-desc">No events yet</p>
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
        </section>
      ) : null}
    </>
  )
}
