import { useCallback, useEffect, useMemo, useState } from 'react'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DeadLink,
  EmptyRow,
  FilterHeader,
  ListCard,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import { listDataStreams, type KinesisStreamRow } from '../lib/kinesis'

export function KinesisStreamsPage() {
  const [streams, setStreams] = useState<KinesisStreamRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listDataStreams()
      setStreams(list)
      setSelected((prev) =>
        prev && list.some((s) => (s.arn || s.name) === prev) ? prev : null,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return streams
    return streams.filter(
      (s) =>
        s.name.toLowerCase().includes(q) ||
        s.arn.toLowerCase().includes(q) ||
        s.status.toLowerCase().includes(q) ||
        s.capacityMode.toLowerCase().includes(q),
    )
  }, [streams, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Data streams"
      desc="Amazon Kinesis Data Streams captures, processes, and stores data streams at any scale so you can build real-time applications."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton title="Select a row">Delete</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create data stream</DeadButton>
        </>
      }
      placeholder="Filter streams by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="kinesis-streams-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Status</FilterHeader>
            <FilterHeader>Capacity mode</FilterHeader>
            <FilterHeader>Monitoring</FilterHeader>
            <SortHeader>Created</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={6}
              loading={loading}
              loadingText="Loading data streams…"
              title="No data streams"
              text="You do not have any data streams in this region."
            />
          ) : (
            filtered.map((s) => {
              const id = s.arn || s.name
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-kinesis-stream"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[s.name, s.arn]} detail={isSelected}>
                      <DeadLink>{s.name}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>{s.status}</td>
                  <td>{s.capacityMode}</td>
                  <td>{s.monitoring}</td>
                  <td>{formatServiceDate(s.createdOn)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
