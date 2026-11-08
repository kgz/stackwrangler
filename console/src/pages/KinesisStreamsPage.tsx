import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  ListCard,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  deleteDataStream,
  listDataStreams,
  type KinesisStreamRow,
} from '../lib/kinesis'

export function KinesisStreamsPage() {
  const [streams, setStreams] = useState<KinesisStreamRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [busy, setBusy] = useState(false)

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

  const selectedStream = useMemo(
    () => streams.find((s) => (s.arn || s.name) === selected) ?? null,
    [streams, selected],
  )

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onDelete() {
    if (!selectedStream) return
    setBusy(true)
    setError(null)
    try {
      await deleteDataStream(selectedStream.name)
      setConfirmDelete(false)
      setSelected(null)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <ListCard
        title="Data streams"
        desc="Amazon Kinesis Data Streams captures, processes, and stores data streams at any scale so you can build real-time applications."
        notices={<Notices error={error} />}
        toolbar={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selectedStream || busy}
              title={selectedStream ? undefined : 'Select a row'}
              onClick={() => setConfirmDelete(true)}
              data-testid="kinesis-delete"
            >
              Delete
            </button>
            <div className="spacer" />
            <Link className="btn btn-primary" to="/kinesis/create">
              Create data stream
            </Link>
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
                        <Link
                          to={`/kinesis/streams/${encodeURIComponent(s.name)}`}
                          onClick={(e) => e.stopPropagation()}
                        >
                          {s.name}
                        </Link>
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

      {confirmDelete && selectedStream ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete data stream?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{selectedStream.name}</strong>.
              In-flight records are discarded.
            </p>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setConfirmDelete(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onDelete()}
                data-testid="kinesis-confirm-delete"
              >
                {busy ? 'Deleting…' : 'Delete data stream'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
