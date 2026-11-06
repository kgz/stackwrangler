import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { getStackTemplate, updateStack } from '../lib/cfn'

export function CloudFormationUpdateStackPage() {
  const { name: rawName } = useParams<{ name: string }>()
  const name = decodeURIComponent(rawName ?? '')
  const navigate = useNavigate()
  const [templateBody, setTemplateBody] = useState('')
  const [source, setSource] = useState<'paste' | 'upload'>('paste')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    void (async () => {
      setLoading(true)
      setError(null)
      try {
        const tpl = await getStackTemplate(name)
        if (!cancelled) setTemplateBody(tpl)
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : String(err))
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [name])

  async function onFile(file: File | null) {
    if (!file) return
    const text = await file.text()
    setTemplateBody(text)
    setSource('upload')
  }

  async function onUpdate() {
    const body = templateBody.trim()
    if (!body) {
      setError('Template body is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await updateStack({ stackName: name, templateBody: body })
      navigate(`/cloudformation/stacks/${encodeURIComponent(name)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const detailPath = `/cloudformation/stacks/${encodeURIComponent(name)}`

  return (
    <>
      <h1 className="aws-h1">Update stack</h1>
      <p className="aws-desc">
        Replace the current template for <strong>{name}</strong>, then submit
        the update.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Stack</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="stack-name">
                Stack name
              </label>
              <input
                className="aws-input"
                id="stack-name"
                name="stackName"
                type="text"
                value={name}
                readOnly
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Specify template</h2>
            <p className="aws-desc" style={{ marginBottom: 12 }}>
              Replace current template — paste YAML/JSON or upload a file.
            </p>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="templateSource"
                    checked={source === 'paste'}
                    onChange={() => setSource('paste')}
                  />
                  <span>
                    <strong>Replace current template</strong>
                    <span className="sub">Paste a new template body.</span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="templateSource"
                    checked={source === 'upload'}
                    onChange={() => setSource('upload')}
                  />
                  <span>
                    <strong>Upload a template file</strong>
                    <span className="sub">
                      Choose a local <code className="aws-mono">.yaml</code> /{' '}
                      <code className="aws-mono">.json</code> file.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
            {source === 'upload' ? (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label className="aws-label" htmlFor="template-file">
                  Template file
                </label>
                <input
                  className="aws-input"
                  id="template-file"
                  type="file"
                  accept=".yaml,.yml,.json,application/json,text/yaml"
                  onChange={(e) => void onFile(e.target.files?.[0] ?? null)}
                />
              </div>
            ) : null}
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label" htmlFor="template-body">
                Template body <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <textarea
                className="aws-input aws-mono"
                id="template-body"
                name="templateBody"
                rows={14}
                spellCheck={false}
                disabled={loading}
                value={templateBody}
                onChange={(e) => setTemplateBody(e.target.value)}
                style={{
                  width: '100%',
                  minHeight: 240,
                  fontFamily: 'ui-monospace, monospace',
                  whiteSpace: 'pre',
                }}
              />
            </div>
          </div>

          <div className="aws-form-actions">
            <Link className="btn btn-normal" to={detailPath}>
              Cancel
            </Link>
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy || loading}
              onClick={() => void onUpdate()}
            >
              Update stack
            </button>
          </div>
        </div>
      </section>
    </>
  )
}
