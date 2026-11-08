import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import { createTopic, type TopicType } from '../lib/sns'

export function SnsCreateTopicPage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [topicType, setTopicType] = useState<TopicType>('standard')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const topicName = name.trim()
    if (!topicName) {
      setError('Topic name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createTopic({
        name: topicName,
        type: topicType,
        displayName,
      })
      navigate(`/sns/topics/${encodeURIComponent(topicName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create topic</h1>
      <p className="aws-desc">
        Create an Amazon SNS topic for application-to-application (A2A) or
        application-to-person (A2P) messaging. LocalEmu supports Standard and
        FIFO topics via <code>CreateTopic</code>.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="topic-name">
                Name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="topic-name"
                name="name"
                type="text"
                autoComplete="off"
                placeholder="my-topic"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="sns-create-name"
              />
              <p className="aws-hint">
                1–256 characters. Letters, numbers, hyphens, and underscores.
                FIFO names must end with <code>.fifo</code>.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="display-name">
                Display name
              </label>
              <input
                className="aws-input"
                id="display-name"
                name="displayName"
                type="text"
                autoComplete="off"
                placeholder="Optional"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                data-testid="sns-create-display-name"
              />
              <p className="aws-hint">
                Shown for SMS and some console views. Optional in LocalEmu.
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
                    name="topicType"
                    value="standard"
                    checked={topicType === 'standard'}
                    onChange={() => setTopicType('standard')}
                    data-testid="sns-type-standard"
                  />
                  <span>
                    <strong>Standard</strong>
                    <span className="sub">
                      Best-effort ordering and at-least-once delivery. Highest
                      throughput.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="topicType"
                    value="fifo"
                    checked={topicType === 'fifo'}
                    onChange={() => setTopicType('fifo')}
                    data-testid="sns-type-fifo"
                  />
                  <span>
                    <strong>FIFO</strong>
                    <span className="sub">
                      Strictly ordered, exactly-once. Name must end with{' '}
                      <code>.fifo</code>.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Additional settings</h2>
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
              <label className="aws-label">Access policy</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Edit access policy…
              </button>
            </div>
            <div className="aws-field">
              <label className="aws-label">Delivery retry policy</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure delivery retry…
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
        <Link className="btn btn-normal" to="/sns">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="sns-create-submit"
        >
          {busy ? 'Creating…' : 'Create topic'}
        </button>
      </div>
    </>
  )
}
