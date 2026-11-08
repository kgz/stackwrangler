import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import {
  deleteQueueMessage,
  describeQueue,
  receiveQueueMessages,
  sendQueueMessage,
  type SqsQueueDetail,
  type SqsReceivedMessage,
} from '../lib/sqs'

function contentBasedDedupEnabled(queue: SqsQueueDetail): boolean {
  return queue.contentBasedDeduplication === 'true'
}

function bodyPreview(body: string): string {
  const oneLine = body.replace(/\s+/g, ' ').trim()
  if (oneLine.length <= 80) return oneLine || '—'
  return `${oneLine.slice(0, 77)}…`
}

function messageSizeLabel(body: string): string {
  const bytes = new TextEncoder().encode(body).length
  return `${bytes} B`
}

export function SqsSendReceivePage() {
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<SqsQueueDetail | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [sendError, setSendError] = useState<string | null>(null)
  const [receiveError, setReceiveError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [messageBody, setMessageBody] = useState('')
  const [delaySeconds, setDelaySeconds] = useState('0')
  const [messageGroupId, setMessageGroupId] = useState('default')
  const [messageDeduplicationId, setMessageDeduplicationId] = useState('')
  const [maxMessages, setMaxMessages] = useState('10')
  const [messages, setMessages] = useState<SqsReceivedMessage[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [polled, setPolled] = useState(false)

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

  async function onSend() {
    if (!detail) return
    const body = messageBody
    if (!body.trim()) {
      setSendError('Message body is required')
      return
    }
    const delay = Number(delaySeconds)
    if (!Number.isFinite(delay) || delay < 0 || delay > 900) {
      setSendError('Delay seconds must be between 0 and 900')
      return
    }
    if (detail.fifoQueue && !messageGroupId.trim()) {
      setSendError('Message group ID is required for FIFO queues')
      return
    }
    const needsDedupId =
      detail.fifoQueue && !contentBasedDedupEnabled(detail)
    if (needsDedupId && !messageDeduplicationId.trim()) {
      setSendError(
        'Message deduplication ID is required when content-based deduplication is off',
      )
      return
    }
    setBusy(true)
    setSendError(null)
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
      setMessageBody('')
      setNotice(
        messageId ? `Message sent (${messageId})` : 'Message sent',
      )
      await refresh()
    } catch (err) {
      setSendError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onPoll() {
    if (!detail) return
    const max = Number(maxMessages)
    if (!Number.isFinite(max) || max < 1 || max > 10) {
      setReceiveError('Max number of messages must be between 1 and 10')
      return
    }
    setBusy(true)
    setReceiveError(null)
    setNotice(null)
    try {
      const next = await receiveQueueMessages({
        queueUrl: detail.url,
        maxNumberOfMessages: max,
        waitTimeSeconds: 1,
      })
      setMessages(next)
      setSelectedId(null)
      setPolled(true)
      setNotice(
        next.length === 0
          ? 'No messages available'
          : `Polled ${next.length} message${next.length === 1 ? '' : 's'}`,
      )
      await refresh()
    } catch (err) {
      setReceiveError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onDeleteSelected() {
    if (!detail || !selectedId) return
    const msg = messages.find((m) => m.messageId === selectedId)
    if (!msg) return
    setBusy(true)
    setReceiveError(null)
    setNotice(null)
    try {
      await deleteQueueMessage(detail.url, msg.receiptHandle)
      setMessages((prev) => prev.filter((m) => m.messageId !== selectedId))
      setSelectedId(null)
      setConfirmDelete(false)
      setNotice(`Deleted message ${msg.messageId}`)
      await refresh()
    } catch (err) {
      setReceiveError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  const title = detail?.name ?? name
  const selected = messages.find((m) => m.messageId === selectedId) ?? null

  return (
    <>
      <h1 className="aws-h1">Send and receive messages</h1>
      <p className="aws-desc">
        Queue <strong>{title || '—'}</strong> · LocalEmu{' '}
        <code>SendMessage</code> / <code>ReceiveMessage</code> /{' '}
        <code>DeleteMessage</code>.
      </p>
      <p className="aws-desc">
        {name ? (
          <Link to={`/sqs/queues/${encodeURIComponent(name)}`}>
            ← {title || name}
          </Link>
        ) : (
          <Link to="/sqs">← Queues</Link>
        )}
      </p>
      <Notices error={error} toast={notice} />
      {loading && !detail ? <p className="aws-desc">Loading…</p> : null}

      {detail ? (
        <>
          <section className="aws-card" data-testid="sqs-send-card">
            <div className="aws-card-body aws-form-stack">
              <h2 className="aws-section-title">Send message</h2>
              <Notices error={sendError} />
              <div className="aws-field">
                <label className="aws-label" htmlFor="sqs-message-body">
                  Body <span className="req">*</span>
                </label>
                <textarea
                  className="aws-input"
                  id="sqs-message-body"
                  rows={6}
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
                      {!contentBasedDedupEnabled(detail) ? (
                        <span className="req">*</span>
                      ) : null}
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
                      placeholder={
                        contentBasedDedupEnabled(detail)
                          ? 'optional when content-based dedup is on'
                          : undefined
                      }
                    />
                  </div>
                </>
              ) : null}
              <div className="aws-field">
                <h2 className="aws-section-title">Message attributes</h2>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled
                  aria-disabled="true"
                  title={TO_IMPLEMENT}
                >
                  Add attribute…
                </button>
              </div>
              <div className="aws-toolbar">
                <div className="spacer" />
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
          </section>

          <section
            className="aws-card"
            style={{ marginTop: 16 }}
            data-testid="sqs-receive-card"
          >
            <div className="aws-card-body">
              <h2 className="aws-section-title">Receive messages</h2>
              <p className="aws-desc">
                Poll peeks with <code>VisibilityTimeout=0</code> so messages
                stay available (AWS console behaviour). Delete removes them via{' '}
                <code>DeleteMessage</code>.
              </p>
              <Notices error={receiveError} />
              <div className="aws-toolbar" style={{ marginBottom: 12 }}>
                <div className="aws-field" style={{ margin: 0 }}>
                  <label className="aws-label" htmlFor="sqs-max-messages">
                    Max number of messages
                  </label>
                  <input
                    className="aws-input"
                    id="sqs-max-messages"
                    type="number"
                    min={1}
                    max={10}
                    value={maxMessages}
                    onChange={(e) => setMaxMessages(e.target.value)}
                    data-testid="sqs-max-messages"
                    style={{ maxWidth: 100 }}
                  />
                </div>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={busy}
                  onClick={() => void onPoll()}
                  data-testid="sqs-poll"
                >
                  {busy ? 'Polling…' : 'Poll for messages'}
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={busy || !selected}
                  title={selected ? undefined : 'Select a row'}
                  onClick={() => setConfirmDelete(true)}
                  data-testid="sqs-delete-message"
                >
                  Delete
                </button>
              </div>
              <table
                className="aws-table"
                data-testid="sqs-messages-table"
              >
                <thead>
                  <tr>
                    <th scope="col" style={{ width: '2.5rem' }} />
                    <th scope="col">Message ID</th>
                    <th scope="col">Body</th>
                    <th scope="col">Size</th>
                    <th scope="col">Receive count</th>
                  </tr>
                </thead>
                <tbody>
                  {messages.length === 0 ? (
                    <tr>
                      <td colSpan={5} className="aws-empty">
                        {polled
                          ? 'No messages returned.'
                          : 'No messages polled yet. Choose Poll for messages.'}
                      </td>
                    </tr>
                  ) : (
                    messages.map((msg) => (
                      <tr key={msg.messageId}>
                        <td>
                          <input
                            type="radio"
                            name="sqs-selected-message"
                            checked={selectedId === msg.messageId}
                            onChange={() => setSelectedId(msg.messageId)}
                            aria-label={`Select ${msg.messageId}`}
                            data-testid={`sqs-msg-select-${msg.messageId}`}
                          />
                        </td>
                        <td>
                          <code className="aws-mono">{msg.messageId}</code>
                        </td>
                        <td>{bodyPreview(msg.body)}</td>
                        <td>{messageSizeLabel(msg.body)}</td>
                        <td>{msg.approximateReceiveCount ?? '—'}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </section>

          <div className="aws-toolbar" style={{ marginTop: 16 }}>
            <Link
              className="btn btn-normal"
              to={`/sqs/queues/${encodeURIComponent(detail.name)}`}
            >
              Back to queue
            </Link>
          </div>
        </>
      ) : null}

      {confirmDelete && selected ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            data-testid="sqs-delete-message-modal"
          >
            <h3>Delete message?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete message{' '}
              <code className="aws-mono">{selected.messageId}</code>.
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
                onClick={() => void onDeleteSelected()}
                data-testid="sqs-confirm-delete-message"
              >
                {busy ? 'Deleting…' : 'Delete'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
