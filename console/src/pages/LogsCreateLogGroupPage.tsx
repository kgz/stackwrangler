import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { createLogGroup, RETENTION_OPTIONS } from '../lib/logs'

export function LogsCreateLogGroupPage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [retention, setRetention] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const logGroupName = name.trim()
    if (!logGroupName) {
      setError('Log group name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const days = retention ? Number(retention) : undefined
      await createLogGroup(
        logGroupName,
        days !== undefined && Number.isFinite(days) ? days : undefined,
      )
      navigate(`/logs/log-groups/${encodeURIComponent(logGroupName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create log group</h1>
      <p className="aws-desc">
        Create a log group. LocalEmu supports <code>CreateLogGroup</code> and
        optional <code>PutRetentionPolicy</code>.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Log group details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="lg-name">
                Log group name <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <input
                className="aws-input"
                id="lg-name"
                name="logGroupName"
                type="text"
                autoComplete="off"
                placeholder="/aws/my-app/prod"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="logs-create-name"
              />
              <p className="aws-hint">
                1–512 characters. Letters, numbers, and the characters _ . / #
                -
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="lg-retention">
                Retention setting
              </label>
              <select
                className="aws-select"
                id="lg-retention"
                name="retentionInDays"
                value={retention}
                onChange={(e) => setRetention(e.target.value)}
                style={{ maxWidth: 480, width: '100%' }}
                data-testid="logs-create-retention"
              >
                {RETENTION_OPTIONS.map((opt) => (
                  <option key={opt.value || 'never'} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <p className="aws-hint">
                Events older than the retention period are deleted
                automatically.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="lg-class">
                Log class
              </label>
              <select
                className="aws-select"
                id="lg-class"
                name="logGroupClass"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option value="STANDARD">Standard</option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/logs">
          Cancel
        </Link>
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="logs-create-submit"
        >
          {busy ? 'Creating…' : 'Create log group'}
        </button>
      </div>
    </>
  )
}
