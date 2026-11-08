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
  deleteQueue,
  listQueues,
  purgeQueue,
  type SqsQueueRow,
} from '../lib/sqs'

export function SqsQueuesPage() {
  const [queues, setQueues] = useState<SqsQueueRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [confirmPurge, setConfirmPurge] = useState(false)
  const [purgeTyped, setPurgeTyped] = useState('')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listQueues()
      setQueues(list)
      setSelected((prev) =>
        prev && list.some((q) => q.url === prev) ? prev : null,
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
    if (!q) return queues
    return queues.filter(
      (row) =>
        row.name.toLowerCase().includes(q) ||
        row.url.toLowerCase().includes(q) ||
        row.type.toLowerCase().includes(q),
    )
  }, [queues, filter])

  const selectedQueue = useMemo(
    () => queues.find((q) => q.url === selected) ?? null,
    [queues, selected],
  )

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onDelete() {
    if (!selectedQueue) return
    setBusy(true)
    setError(null)
    try {
      await deleteQueue(selectedQueue.url)
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

  async function onPurge() {
    if (!selectedQueue) return
    if (purgeTyped.trim().toLowerCase() !== 'purge') {
      setError('Type purge to confirm')
      return
    }
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      await purgeQueue(selectedQueue.url)
      setConfirmPurge(false)
      setPurgeTyped('')
      setNotice(`Purged queue ${selectedQueue.name}`)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmPurge(false)
      setPurgeTyped('')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <ListCard
        title="Queues"
        desc="Amazon Simple Queue Service (SQS) lets you send, store, and receive messages between software components at any volume, without losing messages or requiring other services to be available."
        notices={<Notices error={error} toast={notice} />}
        toolbar={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selectedQueue || busy}
              title={selectedQueue ? undefined : 'Select a row'}
              onClick={() => {
                setError(null)
                setPurgeTyped('')
                setConfirmPurge(true)
              }}
              data-testid="sqs-purge"
            >
              Purge
            </button>
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selectedQueue || busy}
              title={selectedQueue ? undefined : 'Select a row'}
              onClick={() => setConfirmDelete(true)}
              data-testid="sqs-delete"
            >
              Delete
            </button>
            <div className="spacer" />
            <Link className="btn btn-primary" to="/sqs/create">
              Create queue
            </Link>
          </>
        }
        placeholder="Filter queues by name"
        filter={filter}
        onFilter={setFilter}
      >
        <table className="aws-table" data-testid="sqs-queues-table">
          <thead>
            <tr>
              <SelectHeader />
              <SortHeader>Name</SortHeader>
              <FilterHeader>Type</FilterHeader>
              <SortHeader>Created</SortHeader>
              <SortHeader>Messages available</SortHeader>
              <SortHeader>Messages in flight</SortHeader>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 ? (
              <EmptyRow
                colSpan={6}
                loading={loading}
                loadingText="Loading queues…"
                title="No queues"
                text="You do not have any queues in this region."
              />
            ) : (
              filtered.map((row) => {
                const isSelected = selected === row.url
                return (
                  <tr
                    key={row.url}
                    className={`selectable${isSelected ? ' selected' : ''}`}
                    onClick={() => toggle(row.url)}
                  >
                    <SelectCell
                      name="selected-sqs-queue"
                      id={row.url}
                      selected={isSelected}
                      onToggle={toggle}
                    />
                    <td>
                      <ResourceLabel
                        ids={[row.name, row.url]}
                        detail={isSelected}
                      >
                        <Link
                          to={`/sqs/queues/${encodeURIComponent(row.name)}`}
                          onClick={(e) => e.stopPropagation()}
                        >
                          {row.name}
                        </Link>
                      </ResourceLabel>
                    </td>
                    <td>{row.type}</td>
                    <td>{formatServiceDate(row.createdOn)}</td>
                    <td>{row.messagesAvailable}</td>
                    <td>{row.messagesInFlight}</td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </ListCard>

      {confirmDelete && selectedQueue ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete queue?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{selectedQueue.name}</strong>. Messages
              still in the queue are discarded.
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
                data-testid="sqs-confirm-delete"
              >
                {busy ? 'Deleting…' : 'Delete queue'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {confirmPurge && selectedQueue ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            data-testid="sqs-purge-modal"
          >
            <h3>Purge queue?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Delete all messages in <strong>{selectedQueue.name}</strong>,
              including in-flight messages. This cannot be undone. Type{' '}
              <code>purge</code> to confirm.
            </p>
            <div className="aws-field">
              <label className="aws-label" htmlFor="sqs-list-purge-confirm">
                Confirm
              </label>
              <input
                className="aws-input"
                id="sqs-list-purge-confirm"
                type="text"
                value={purgeTyped}
                onChange={(e) => setPurgeTyped(e.target.value)}
                data-testid="sqs-purge-confirm-input"
                autoComplete="off"
              />
            </div>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => {
                  setConfirmPurge(false)
                  setPurgeTyped('')
                }}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={
                  busy || purgeTyped.trim().toLowerCase() !== 'purge'
                }
                onClick={() => void onPurge()}
                data-testid="sqs-confirm-purge"
              >
                {busy ? 'Purging…' : 'Purge'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

    </>
  )
}
