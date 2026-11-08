import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { DeadButton } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import { createEventBus } from '../lib/events'

export function EventBridgeCreateBusPage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const busName = name.trim()
    if (!busName) {
      setError('Event bus name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createEventBus({ name: busName, description })
      navigate('/events/buses')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create event bus</h1>
      <p className="aws-desc">
        Create a custom event bus to receive events from your applications and
        partners. LocalEmu accepts <code>CreateEventBus</code>.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Event bus details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="bus-name">
                Name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="bus-name"
                name="name"
                type="text"
                autoComplete="off"
                placeholder="my-event-bus"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="events-create-bus-name"
              />
              <p className="aws-hint">
                1–256 characters. Cannot be <code>default</code>.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="bus-description">
                Description
              </label>
              <input
                className="aws-input"
                id="bus-description"
                name="description"
                type="text"
                autoComplete="off"
                placeholder="Optional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                data-testid="events-create-bus-description"
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Additional settings</h2>
            <div className="aws-field">
              <label className="aws-label">Resource-based policy</label>
              <DeadButton>Add policy…</DeadButton>
            </div>
            <div className="aws-field">
              <label className="aws-label">Tags</label>
              <DeadButton>Add tags…</DeadButton>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/events/buses">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="events-create-bus-submit"
        >
          {busy ? 'Creating…' : 'Create event bus'}
        </button>
      </div>
    </>
  )
}
