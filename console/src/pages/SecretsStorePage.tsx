import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { createSecret } from '../lib/secrets'

export function SecretsStorePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [secretString, setSecretString] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onStore() {
    const secretName = name.trim()
    if (!secretName) {
      setError('Secret name is required')
      return
    }
    if (!secretString) {
      setError('Secret string is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const created = await createSecret({
        name: secretName,
        secretString,
        description: description.trim() || undefined,
      })
      navigate(`/secretsmanager/secrets/${created.name}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Store a new secret</h1>
      <p className="aws-desc">
        Create a plaintext string secret in this region. Binary secrets,
        RDS/DocumentDB/Redshift credential templates, and automatic rotation
        stay out of this local subset.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Secret type</h2>
          <div
            className="aws-choice-row"
            role="group"
            aria-label="Secret type"
          >
            <button
              type="button"
              className="aws-choice is-selected"
              aria-pressed="true"
            >
              <span>
                <strong>Other type of secret</strong>
                <span>API keys, OAuth tokens, or arbitrary plaintext.</span>
              </span>
            </button>
            <button
              type="button"
              className="aws-choice"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
            >
              <span>
                <strong>Credentials for Amazon RDS database</strong>
                <span>Username / password JSON for an RDS instance.</span>
              </span>
            </button>
            <button
              type="button"
              className="aws-choice"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
            >
              <span>
                <strong>Credentials for Amazon DocumentDB</strong>
                <span>Not wired in this local subset.</span>
              </span>
            </button>
          </div>
        </div>
      </section>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Secret value</h2>
            <div className="aws-field">
              <label className="aws-label">Value format</label>
              <ul className="aws-radio-list">
                <li>
                  <label>
                    <input type="radio" name="valueFormat" defaultChecked />
                    <span>
                      <strong>Plaintext</strong>
                      <span className="sub">
                        Stored as <code className="aws-mono">SecretString</code>
                        .
                      </span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="valueFormat"
                      disabled
                      aria-disabled="true"
                      title={TO_IMPLEMENT}
                    />
                    <span>
                      <strong>Key/value</strong>
                      <span className="sub">JSON object built from rows.</span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="valueFormat"
                      disabled
                      aria-disabled="true"
                      title={TO_IMPLEMENT}
                    />
                    <span>
                      <strong>Binary</strong>
                      <span className="sub">Upload a binary blob.</span>
                    </span>
                  </label>
                </li>
              </ul>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="secret-string">
                Secret string <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <textarea
                className="aws-input"
                id="secret-string"
                name="secretString"
                rows={6}
                autoComplete="off"
                placeholder='{"client_id":"…","client_secret":"…"}'
                value={secretString}
                onChange={(e) => setSecretString(e.target.value)}
                data-testid="secret-string"
              />
              <p className="aws-hint">
                LocalEmu stores this as a string secret. Encryption key defaults
                to the AWS-managed Secrets Manager key.
              </p>
            </div>
          </div>
        </div>
      </section>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Secret name and description</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="secret-name">
                Secret name <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <input
                className="aws-input"
                id="secret-name"
                name="secretName"
                type="text"
                autoComplete="off"
                placeholder="app/oauth/client"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="secret-name"
              />
              <p className="aws-hint">
                1–512 characters. Letters, numbers, and{' '}
                <code className="aws-mono">/_+=.@-</code>.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="secret-desc">
                Description
              </label>
              <input
                className="aws-input"
                id="secret-desc"
                name="description"
                type="text"
                placeholder="Optional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                data-testid="secret-description"
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="secret-kms">
                Encryption key
              </label>
              <select
                className="aws-select"
                id="secret-kms"
                name="kmsKeyId"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option>aws/secretsmanager (default)</option>
              </select>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Rotation</h2>
            <p className="aws-desc" style={{ marginBottom: 12 }}>
              Automatic rotation is not wired against LocalEmu in this pass.
              Store the secret without configuring a rotation Lambda.
            </p>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input type="radio" name="rotation" defaultChecked />
                  <span>
                    <strong>Disable automatic rotation</strong>
                    <span className="sub">
                      Recommended for this local subset.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="rotation"
                    disabled
                    aria-disabled="true"
                    title={TO_IMPLEMENT}
                  />
                  <span>
                    <strong>Enable automatic rotation</strong>
                    <span className="sub">Requires a rotation Lambda.</span>
                  </span>
                </label>
              </li>
            </ul>
          </div>

          <div className="aws-form-actions">
            <Link className="btn btn-normal" to="/secretsmanager">
              Cancel
            </Link>
            <div className="spacer" style={{ flex: 1 }} />
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy}
              onClick={() => void onStore()}
              data-testid="store-secret"
            >
              {busy ? 'Storing…' : 'Store'}
            </button>
          </div>
        </div>
      </section>
    </>
  )
}
