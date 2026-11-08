import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { createRestApi } from '../lib/apigwRest'

export function ApiGatewayRestApiCreatePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const apiName = name.trim()
    if (!apiName) {
      setError('API name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const id = await createRestApi({
        name: apiName,
        description: description.trim() || undefined,
      })
      navigate(`/apigateway/rest-apis/${encodeURIComponent(id)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create REST API</h1>
      <p className="aws-desc">
        Create an empty REST API, then add resources and methods and deploy a
        stage. Import from OpenAPI stays on the CLI / Serverless path for now.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Choose an API type</h2>
          <div className="aws-choice-row" role="group" aria-label="API type">
            <button
              type="button"
              className="aws-choice is-selected"
              aria-pressed="true"
            >
              <span>
                <strong>New API</strong>
                <span>Start with an empty REST API (Regional).</span>
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
                <strong>Clone from existing</strong>
                <span>Copy resources and methods from another API.</span>
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
                <strong>Import from OpenAPI</strong>
                <span>Use an OpenAPI 3 definition.</span>
              </span>
            </button>
          </div>
        </div>
      </section>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Settings</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="api-name">
                API name <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <input
                className="aws-input"
                id="api-name"
                name="apiName"
                type="text"
                autoComplete="off"
                placeholder="my-rest-api"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="rest-api-create-name"
              />
              <p className="aws-hint">
                Letters, numbers, and spaces. Shown in the REST APIs list.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="api-desc">
                Description — optional
              </label>
              <input
                className="aws-input"
                id="api-desc"
                name="description"
                type="text"
                placeholder="Optional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                data-testid="rest-api-create-description"
              />
            </div>
            <div className="aws-field">
              <label className="aws-label">API endpoint type</label>
              <ul className="aws-radio-list">
                <li>
                  <label>
                    <input type="radio" name="endpointType" value="REGIONAL" defaultChecked />
                    <span>
                      <strong>Regional</strong>
                      <span className="sub">
                        Default for LocalEmu. Clients call the regional endpoint.
                      </span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="endpointType"
                      value="EDGE"
                      disabled
                      title={TO_IMPLEMENT}
                    />
                    <span>
                      <strong>Edge-optimized</strong>
                      <span className="sub">
                        CloudFront distribution in front of the API.
                      </span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="endpointType"
                      value="PRIVATE"
                      disabled
                      title={TO_IMPLEMENT}
                    />
                    <span>
                      <strong>Private</strong>
                      <span className="sub">
                        Accessible only from a VPC endpoint.
                      </span>
                    </span>
                  </label>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/apigateway/rest-apis">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="rest-api-create-submit"
        >
          {busy ? 'Creating…' : 'Create API'}
        </button>
      </div>
    </>
  )
}
