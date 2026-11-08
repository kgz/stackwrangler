import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import type { LogGroup } from '@aws-sdk/client-cloudwatch-logs'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
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
import { listLogGroups, retentionLabel } from '../lib/logs'

function groupHref(name: string): string {
  return `/logs/log-groups/${encodeURIComponent(name)}`
}

export function LogsPage() {
  const [groups, setGroups] = useState<LogGroup[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

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

  useEffect(() => {
    void refreshGroups()
  }, [refreshGroups])

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return groups
    return groups.filter((g) =>
      (g.logGroupName ?? '').toLowerCase().includes(q),
    )
  }, [groups, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Log groups"
      desc="A log group is a group of log streams that share the same retention, monitoring, and access control settings."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refreshGroups()} />
          <DeadButton title={selected ? undefined : 'Select a row'}>
            Actions ▾
          </DeadButton>
          <div className="spacer" />
          <Link className="btn btn-primary" to="/logs/create">
            Create log group
          </Link>
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
                        <Link
                          to={groupHref(name)}
                          onClick={(e) => e.stopPropagation()}
                        >
                          {name}
                        </Link>
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
  )
}
