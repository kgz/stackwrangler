import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { RefreshButton, TO_IMPLEMENT } from '../components/S3Ui'
import { DetailHeader, Kv, Mono, Notices } from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  deleteQueue,
  describeQueue,
  purgeQueue,
  type SqsQueueDetail,
} from '../lib/sqs'

export function SqsQueueDetailPage() {
  const navigate = useNavigate()
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<SqsQueueDetail | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [confirmPurge, setConfirmPurge] = useState(false)
  const [purgeTyped, setPurgeTyped] = useState('')
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      setDetail(await describeQueue(name))
    } catch (err) {
      setDetail(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onDelete() {
    if (!detail) return
    setBusy(true)
    setError(null)
    try {
      await deleteQueue(detail.url)
      navigate('/sqs')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  async function onPurge() {
    if (!detail) return
    if (purgeTyped.trim().toLowerCase() !== 'purge') {
      setError('Type purge to confirm')
      return
    }
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      await purgeQueue(detail.url)
      setConfirmPurge(false)
      setPurgeTyped('')
      setNotice(`Purged queue ${detail.name}`)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmPurge(false)
      setPurgeTyped('')
    } finally {
      setBusy(false)
    }
  }

  const title = detail?.name ?? name

  const detailRows = useMemo((): Array<[string, ReactNode]> => {
    if (!detail) return []
    const rows: Array<[string, ReactNode]> = [
      ['Name', detail.name],
      ['Type', detail.type],
      ['URL', <Mono key="url">{detail.url}</Mono>],
      ['ARN', <Mono key="arn">{detail.arn || '—'}</Mono>],
      ['Created', formatServiceDate(detail.createdOn)],
      ['Messages available', detail.messagesAvailable],
      ['Messages in flight', detail.messagesInFlight],
      ['Messages delayed', detail.messagesDelayed],
      ['Visibility timeout', `${detail.visibilityTimeout} seconds`],
      [
        'Message retention period',
        `${detail.messageRetentionPeriod} seconds`,
      ],
      ['Delivery delay', `${detail.delaySeconds} seconds`],
      [
        'Receive message wait time',
        `${detail.receiveMessageWaitTimeSeconds} seconds`,
      ],
      ['Maximum message size', `${detail.maximumMessageSize} bytes`],
    ]
    if (detail.fifoQueue) {
      rows.push([
        'Content-based deduplication',
        detail.contentBasedDeduplication ?? '—',
      ])
    }
    return rows
  }, [detail])

  return (
    <>
      <DetailHeader
        title={title}
        subtitle={
          <>
            <span>{detail?.type ?? '—'}</span>
            <span>Created {formatServiceDate(detail?.createdOn)}</span>
            <span>
              {detail?.messagesAvailable ?? '—'} available ·{' '}
              {detail?.messagesInFlight ?? '—'} in flight
            </span>
          </>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy || !detail}
              onClick={() => {
                setError(null)
                setPurgeTyped('')
                setConfirmPurge(true)
              }}
              data-testid="sqs-detail-purge"
            >
              Purge
            </button>
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy || !detail}
              onClick={() => setConfirmDelete(true)}
              data-testid="sqs-detail-delete"
            >
              Delete
            </button>
            {detail ? (
              <Link
                className="btn btn-primary"
                to={`/sqs/queues/${encodeURIComponent(detail.name)}/send-receive`}
                data-testid="sqs-send-open"
              >
                Send and receive messages
              </Link>
            ) : (
              <button
                type="button"
                className="btn btn-primary"
                disabled
                data-testid="sqs-send-open"
              >
                Send and receive messages
              </button>
            )}
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/sqs">← Queues</Link>
      </p>
      <Notices error={error} toast={notice} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          <button
            type="button"
            className="aws-tab active"
            aria-current="page"
            data-testid="sqs-tab-details"
          >
            Details
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title={TO_IMPLEMENT}
          >
            Monitoring
          </button>
        </div>
        <div className="aws-card-body">
          {loading && !detail ? <p className="aws-desc">Loading…</p> : null}
          {detail ? (
            <>
              <h2 className="aws-section-title">Queue details</h2>
              <p className="aws-desc">
                Attributes from LocalEmu <code>GetQueueAttributes</code>.
              </p>
              <Kv rows={detailRows} />
            </>
          ) : null}
        </div>
      </section>

      {confirmDelete ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete queue?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{title}</strong>. Messages still in
              the queue are discarded.
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

      {confirmPurge && detail ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            data-testid="sqs-purge-modal"
          >
            <h3>Purge queue?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Delete all messages in <strong>{detail.name}</strong>, including
              in-flight messages. This cannot be undone. Type{' '}
              <code>purge</code> to confirm.
            </p>
            <div className="aws-field">
              <label className="aws-label" htmlFor="sqs-purge-confirm">
                Confirm
              </label>
              <input
                className="aws-input"
                id="sqs-purge-confirm"
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
