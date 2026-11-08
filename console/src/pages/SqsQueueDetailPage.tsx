import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { RefreshButton, TO_IMPLEMENT } from '../components/S3Ui'
import { DetailHeader, Kv, Mono, Notices } from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  deleteQueue,
  describeQueue,
  sendQueueMessage,
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
  const [sendOpen, setSendOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [messageBody, setMessageBody] = useState('')
  const [delaySeconds, setDelaySeconds] = useState('0')
  const [messageGroupId, setMessageGroupId] = useState('default')
  const [messageDeduplicationId, setMessageDeduplicationId] = useState('')

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

  async function onSend() {
    if (!detail) return
    const body = messageBody
    if (!body.trim()) {
      setError('Message body is required')
      return
    }
    const delay = Number(delaySeconds)
    if (!Number.isFinite(delay) || delay < 0 || delay > 900) {
      setError('Delay seconds must be between 0 and 900')
      return
    }
    if (detail.fifoQueue && !messageGroupId.trim()) {
      setError('Message group ID is required for FIFO queues')
      return
    }
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const messageId = await sendQueueMessage({
        queueUrl: detail.url,
        body,
        delaySeconds: delay,
        messageGroupId: detail.fifoQueue
          ? messageGroupId.trim()
          : undefined,
        messageDeduplicationId:
          detail.fifoQueue && messageDeduplicationId.trim()
            ? messageDeduplicationId.trim()
            : undefined,
      })
      setSendOpen(false)
      setMessageBody('')
      setNotice(
        messageId
          ? `Message sent (${messageId})`
          : 'Message sent',
      )
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
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
              onClick={() => setConfirmDelete(true)}
              data-testid="sqs-detail-delete"
            >
              Delete
            </button>
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy || !detail}
              onClick={() => {
                setNotice(null)
                setSendOpen(true)
              }}
              data-testid="sqs-send-open"
            >
              Send and receive messages
            </button>
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

      {sendOpen && detail ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            style={{ maxWidth: 640, width: '100%' }}
          >
            <h3>Send message</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Send a message to <strong>{detail.name}</strong> via{' '}
              <code>SendMessage</code>.
            </p>
            <div className="aws-form-stack">
              <div className="aws-field">
                <label className="aws-label" htmlFor="sqs-message-body">
                  Body <span className="req">*</span>
                </label>
                <textarea
                  className="aws-input"
                  id="sqs-message-body"
                  rows={8}
                  value={messageBody}
                  onChange={(e) => setMessageBody(e.target.value)}
                  data-testid="sqs-send-body"
                />
              </div>
              <div className="aws-field">
                <label className="aws-label" htmlFor="sqs-delay-seconds">
                  Delay seconds
                </label>
                <input
                  className="aws-input"
                  id="sqs-delay-seconds"
                  type="number"
                  min={0}
                  max={900}
                  value={delaySeconds}
                  onChange={(e) => setDelaySeconds(e.target.value)}
                  data-testid="sqs-send-delay"
                  style={{ maxWidth: 160 }}
                />
              </div>
              {detail.fifoQueue ? (
                <>
                  <div className="aws-field">
                    <label
                      className="aws-label"
                      htmlFor="sqs-message-group-id"
                    >
                      Message group ID <span className="req">*</span>
                    </label>
                    <input
                      className="aws-input"
                      id="sqs-message-group-id"
                      type="text"
                      value={messageGroupId}
                      onChange={(e) => setMessageGroupId(e.target.value)}
                      data-testid="sqs-send-group-id"
                    />
                  </div>
                  <div className="aws-field">
                    <label
                      className="aws-label"
                      htmlFor="sqs-message-dedup-id"
                    >
                      Message deduplication ID
                    </label>
                    <input
                      className="aws-input"
                      id="sqs-message-dedup-id"
                      type="text"
                      value={messageDeduplicationId}
                      onChange={(e) =>
                        setMessageDeduplicationId(e.target.value)
                      }
                      data-testid="sqs-send-dedup-id"
                    />
                  </div>
                </>
              ) : null}
            </div>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setSendOpen(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onSend()}
                data-testid="sqs-send-submit"
              >
                {busy ? 'Sending…' : 'Send message'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
