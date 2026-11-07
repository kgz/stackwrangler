import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { createChangeSet, getStackTemplate } from '../lib/cfn'

export function CloudFormationCreateChangeSetPage() {
  const { name: rawName } = useParams<{ name: string }>()
  const name = decodeURIComponent(rawName ?? '')
  const navigate = useNavigate()
  const [changeSetName, setChangeSetName] = useState('')
  const [description, setDescription] = useState('')
  const [templateBody, setTemplateBody] = useState('')
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
    setTemplateBody(await file.text())
  }

  async function onCreate() {
    const csName = changeSetName.trim()
    const body = templateBody.trim()
    if (!csName) {
      setError('Change set name is required')
      return
    }
    if (!body) {
      setError('Template body is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createChangeSet({
        stackName: name,
        changeSetName: csName,
        description: description.trim() || undefined,
        templateBody: body,
      })
      navigate(
        `/cloudformation/stacks/${encodeURIComponent(name)}/change-sets/${encodeURIComponent(csName)}`,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const detailPath = `/cloudformation/stacks/${encodeURIComponent(name)}`

  return (
    <>
      <h1 className="aws-h1">Create change set</h1>
      <p className="aws-desc">
        Preview changes for <strong>{name}</strong> before executing.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Change set details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="stack-name">
                Stack name
              </label>
              <input
                className="aws-input"
                id="stack-name"
                type="text"
                value={name}
                readOnly
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="changeset-name">
                Change set name{' '}
                <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <input
                className="aws-input"
                id="changeset-name"
                type="text"
                autoComplete="off"
                placeholder="my-change-set"
                value={changeSetName}
                onChange={(e) => setChangeSetName(e.target.value)}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="changeset-desc">
                Description
              </label>
              <input
                className="aws-input"
                id="changeset-desc"
                type="text"
                placeholder="Optional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Specify template</h2>
            <p className="aws-desc" style={{ marginBottom: 12 }}>
              Replace current template for this change set.
            </p>
            <div className="aws-field">
              <label className="aws-label" htmlFor="template-body">
                Template body{' '}
                <span className="req" aria-hidden="true">
                  *
                </span>
              </label>
              <textarea
                className="aws-input aws-mono"
                id="template-body"
                rows={12}
                spellCheck={false}
                disabled={loading}
                value={templateBody}
                onChange={(e) => setTemplateBody(e.target.value)}
                style={{
                  width: '100%',
                  minHeight: 220,
                  fontFamily: 'ui-monospace, monospace',
                  whiteSpace: 'pre',
                }}
              />
            </div>
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label" htmlFor="template-file">
                Or upload a template file
              </label>
              <input
                className="aws-input"
                id="template-file"
                type="file"
                accept=".yaml,.yml,.json,application/json,text/yaml"
                onChange={(e) => void onFile(e.target.files?.[0] ?? null)}
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
              onClick={() => void onCreate()}
            >
              Create change set
            </button>
          </div>
        </div>
      </section>
    </>
  )
}
