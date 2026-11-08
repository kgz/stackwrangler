import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import { createQueue, type SqsQueueType } from '../lib/sqs'

export function SqsCreateQueuePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [queueType, setQueueType] = useState<SqsQueueType>('Standard')
  const [contentBasedDeduplication, setContentBasedDeduplication] =
    useState(false)
  const [visibilityTimeout, setVisibilityTimeout] = useState('30')
  const [messageRetentionPeriod, setMessageRetentionPeriod] =
    useState('345600')
  const [delaySeconds, setDelaySeconds] = useState('0')
  const [receiveMessageWaitTimeSeconds, setReceiveMessageWaitTimeSeconds] =
    useState('0')
  const [maximumMessageSize, setMaximumMessageSize] = useState('262144')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  function onTypeChange(next: SqsQueueType) {
    setQueueType(next)
    setName((cur) => {
      const trimmed = cur.trim()
      if (next === 'FIFO') {
        if (!trimmed) return cur
        return trimmed.endsWith('.fifo') ? cur : `${trimmed}.fifo`
      }
      if (trimmed.endsWith('.fifo')) {
        return trimmed.slice(0, -'.fifo'.length)
      }
      return cur
    })
  }

  async function onCreate() {
    const queueName = name.trim()
    if (!queueName) {
      setError('Queue name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createQueue({
        name: queueName,
        type: queueType,
        contentBasedDeduplication:
          queueType === 'FIFO' ? contentBasedDeduplication : undefined,
        visibilityTimeout,
        messageRetentionPeriod,
        delaySeconds,
        receiveMessageWaitTimeSeconds,
        maximumMessageSize,
      })
      navigate(`/sqs/queues/${encodeURIComponent(queueName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create queue</h1>
      <p className="aws-desc">
        Create a Standard or FIFO queue. LocalEmu maps this form to{' '}
        <code>CreateQueue</code> with the attributes below.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="queue-name">
                Name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="queue-name"
                name="name"
                type="text"
                autoComplete="off"
                placeholder={
                  queueType === 'FIFO' ? 'my-queue.fifo' : 'my-queue'
                }
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="sqs-create-name"
              />
              <p className="aws-hint">
                Up to 80 characters. FIFO names must end with{' '}
                <code>.fifo</code>.
              </p>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Type</h2>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="queueType"
                    value="Standard"
                    checked={queueType === 'Standard'}
                    onChange={() => onTypeChange('Standard')}
                    data-testid="sqs-type-standard"
                  />
                  <span>
                    <strong>Standard</strong>
                    <span className="sub">
                      Unlimited throughput, at-least-once delivery, best-effort
                      ordering.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="queueType"
                    value="FIFO"
                    checked={queueType === 'FIFO'}
                    onChange={() => onTypeChange('FIFO')}
                    data-testid="sqs-type-fifo"
                  />
                  <span>
                    <strong>FIFO</strong>
                    <span className="sub">
                      Exactly-once processing and first-in-first-out ordering
                      within a message group.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
            {queueType === 'FIFO' ? (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label>
                  <input
                    type="checkbox"
                    checked={contentBasedDeduplication}
                    onChange={(e) =>
                      setContentBasedDeduplication(e.target.checked)
                    }
                    data-testid="sqs-content-based"
                  />{' '}
                  Content-based deduplication (FIFO)
                </label>
                <p className="aws-hint">
                  When enabled, SQS can generate a deduplication ID from the
                  message body.
                </p>
              </div>
            ) : null}
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Configuration</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="visibility-timeout">
                Visibility timeout (seconds)
              </label>
              <input
                className="aws-input"
                id="visibility-timeout"
                type="number"
                min={0}
                max={43200}
                value={visibilityTimeout}
                onChange={(e) => setVisibilityTimeout(e.target.value)}
                data-testid="sqs-create-visibility"
                style={{ maxWidth: 160 }}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="message-retention">
                Message retention period (seconds)
              </label>
              <input
                className="aws-input"
                id="message-retention"
                type="number"
                min={60}
                max={1209600}
                value={messageRetentionPeriod}
                onChange={(e) => setMessageRetentionPeriod(e.target.value)}
                data-testid="sqs-create-retention"
                style={{ maxWidth: 160 }}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="delivery-delay">
                Delivery delay (seconds)
              </label>
              <input
                className="aws-input"
                id="delivery-delay"
                type="number"
                min={0}
                max={900}
                value={delaySeconds}
                onChange={(e) => setDelaySeconds(e.target.value)}
                data-testid="sqs-create-delay"
                style={{ maxWidth: 160 }}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="receive-wait">
                Receive message wait time (seconds)
              </label>
              <input
                className="aws-input"
                id="receive-wait"
                type="number"
                min={0}
                max={20}
                value={receiveMessageWaitTimeSeconds}
                onChange={(e) =>
                  setReceiveMessageWaitTimeSeconds(e.target.value)
                }
                data-testid="sqs-create-receive-wait"
                style={{ maxWidth: 160 }}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="max-message-size">
                Maximum message size (bytes)
              </label>
              <input
                className="aws-input"
                id="max-message-size"
                type="number"
                min={1024}
                max={262144}
                value={maximumMessageSize}
                onChange={(e) => setMaximumMessageSize(e.target.value)}
                data-testid="sqs-create-max-size"
                style={{ maxWidth: 160 }}
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Additional settings</h2>
            <div className="aws-field">
              <label className="aws-label">Access policy</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure access policy…
              </button>
            </div>
            <div className="aws-field">
              <label className="aws-label">Encryption</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure encryption…
              </button>
            </div>
            <div className="aws-field">
              <label className="aws-label">Dead-letter queue</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure redrive…
              </button>
            </div>
            <div className="aws-field">
              <label className="aws-label">Tags</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Add tags…
              </button>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/sqs">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="sqs-create-submit"
        >
          {busy ? 'Creating…' : 'Create queue'}
        </button>
      </div>
    </>
  )
}
