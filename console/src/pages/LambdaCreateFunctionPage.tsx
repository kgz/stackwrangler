import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Mono, Notices } from '../components/ServiceUi'
import { TO_IMPLEMENT } from '../components/S3Ui'
import {
  BASIC_ROLE_NAME,
  createFunctionFromForm,
  listExecutionRoles,
  readFileAsBytes,
  type RoleOption,
} from '../lib/lambda'

const RUNTIMES = [
  { value: 'nodejs20.x', label: 'Node.js 20.x' },
  { value: 'nodejs18.x', label: 'Node.js 18.x' },
  { value: 'python3.12', label: 'Python 3.12' },
  { value: 'python3.11', label: 'Python 3.11' },
  { value: 'java21', label: 'Java 21' },
  { value: 'provided.al2023', label: 'Custom runtime on Amazon Linux 2023' },
] as const

export function LambdaCreateFunctionPage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [runtime, setRuntime] = useState<string>('nodejs20.x')
  const [architecture, setArchitecture] = useState<'x86_64' | 'arm64'>(
    'x86_64',
  )
  const [roleMode, setRoleMode] = useState<'create' | 'existing'>('create')
  const [roles, setRoles] = useState<RoleOption[]>([])
  const [existingRoleArn, setExistingRoleArn] = useState('')
  const [codeSource, setCodeSource] = useState<'hello' | 'zip'>('hello')
  const [zipFile, setZipFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    void listExecutionRoles()
      .then((list) => {
        setRoles(list)
        setExistingRoleArn((cur) => cur || list[0]?.arn || '')
      })
      .catch(() => {
        setRoles([{ name: BASIC_ROLE_NAME, arn: '' }])
      })
  }, [])

  async function onCreate() {
    const functionName = name.trim()
    if (!functionName) {
      setError('Function name is required')
      return
    }
    if (codeSource === 'zip' && !zipFile) {
      setError('Select a .zip deployment package')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const zipBytes =
        codeSource === 'zip' && zipFile
          ? await readFileAsBytes(zipFile)
          : undefined
      await createFunctionFromForm({
        name: functionName,
        runtime,
        description: description.trim() || undefined,
        architecture,
        roleMode,
        existingRoleArn: existingRoleArn || undefined,
        codeSource,
        zipBytes,
      })
      navigate(`/lambda/functions/${encodeURIComponent(functionName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create function</h1>
      <p className="aws-desc">
        Configure a new function. Author from scratch uses a Hello world
        template or a .zip upload.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Choose create options</h2>
          <div className="aws-choice-row" role="group" aria-label="Create method">
            <button
              type="button"
              className="aws-choice is-selected"
              aria-pressed="true"
            >
              <span>
                <strong>Author from scratch</strong>
                <span>Start with a basic Hello world example.</span>
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
                <strong>Use a blueprint</strong>
                <span>Build from sample code and configuration.</span>
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
                <strong>Container image</strong>
                <span>Select a container image from a registry.</span>
              </span>
            </button>
          </div>
        </div>
      </section>

      <section className="aws-card aws-card-flush" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Basic information</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="fn-name">
                Function name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="fn-name"
                name="functionName"
                type="text"
                autoComplete="off"
                placeholder="my-function"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="lambda-create-name"
              />
              <p className="aws-hint">
                1–64 characters. Use letters, numbers, hyphens, underscores, or
                periods.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="fn-desc">
                Description
              </label>
              <input
                className="aws-input"
                id="fn-desc"
                type="text"
                placeholder="Optional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="fn-runtime">
                Runtime <span className="req">*</span>
              </label>
              <select
                className="aws-select aws-input"
                id="fn-runtime"
                value={runtime}
                onChange={(e) => setRuntime(e.target.value)}
              >
                {RUNTIMES.map((r) => (
                  <option key={r.value} value={r.value}>
                    {r.label}
                  </option>
                ))}
              </select>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="fn-arch">
                Architecture
              </label>
              <select
                className="aws-select aws-input"
                id="fn-arch"
                value={architecture}
                onChange={(e) =>
                  setArchitecture(e.target.value === 'arm64' ? 'arm64' : 'x86_64')
                }
              >
                <option value="x86_64">x86_64</option>
                <option value="arm64">arm64</option>
              </select>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Permissions</h2>
            <p className="aws-desc" style={{ marginBottom: 12 }}>
              Choose an execution role so Lambda can write logs and access
              resources.
            </p>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="roleMode"
                    checked={roleMode === 'create'}
                    onChange={() => setRoleMode('create')}
                  />
                  <span>
                    <strong>Create a new role with basic Lambda permissions</strong>
                    <span className="sub">
                      Creates <Mono>{BASIC_ROLE_NAME}</Mono> if it does not
                      exist.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="roleMode"
                    checked={roleMode === 'existing'}
                    onChange={() => setRoleMode('existing')}
                  />
                  <span>
                    <strong>Use an existing role</strong>
                    <span className="sub">
                      Select a role that trusts lambda.amazonaws.com.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input type="radio" name="roleMode" disabled title="To implement" />
                  <span>
                    <strong>Create a new role from AWS policy templates</strong>
                    <span className="sub">
                      Attach managed policy templates when creating the role.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
            {roleMode === 'existing' ? (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label className="aws-label" htmlFor="fn-role">
                  Existing role
                </label>
                <select
                  className="aws-select aws-input"
                  id="fn-role"
                  value={existingRoleArn}
                  onChange={(e) => setExistingRoleArn(e.target.value)}
                >
                  {roles.map((r) => (
                    <option key={r.arn || r.name} value={r.arn || r.name}>
                      {r.name}
                    </option>
                  ))}
                </select>
              </div>
            ) : null}
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Code source</h2>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="codeSource"
                    checked={codeSource === 'hello'}
                    onChange={() => setCodeSource('hello')}
                  />
                  <span>
                    <strong>Hello world function</strong>
                    <span className="sub">
                      Ship a minimal <Mono>index.handler</Mono> for the selected
                      runtime.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="codeSource"
                    checked={codeSource === 'zip'}
                    onChange={() => setCodeSource('zip')}
                  />
                  <span>
                    <strong>Upload from .zip file</strong>
                    <span className="sub">
                      Provide a deployment package under 50 MB (console upload).
                    </span>
                  </span>
                </label>
              </li>
            </ul>
            {codeSource === 'zip' ? (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label className="aws-label" htmlFor="fn-zip">
                  .zip file
                </label>
                <input
                  className="aws-input"
                  id="fn-zip"
                  type="file"
                  accept=".zip,application/zip"
                  onChange={(e) => setZipFile(e.target.files?.[0] ?? null)}
                />
                <p className="aws-hint">
                  Select a .zip deployment package for LocalEmu.
                </p>
              </div>
            ) : null}
          </div>

          <div className="aws-form-actions">
            <Link className="btn btn-normal" to="/lambda">
              Cancel
            </Link>
            <div className="spacer" style={{ flex: 1 }} />
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy}
              onClick={() => void onCreate()}
              data-testid="lambda-create-submit"
            >
              {busy ? 'Creating…' : 'Create function'}
            </button>
          </div>
        </div>
      </section>
    </>
  )
}
