import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import {
  BASIC_SFN_ROLE_NAME,
  DEFAULT_PASS_DEFINITION,
  createStateMachineFromForm,
  listExecutionRoles,
  type RoleOption,
} from '../lib/sfn'

export function StepFunctionsCreatePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [smType, setSmType] = useState<'STANDARD' | 'EXPRESS'>('STANDARD')
  const [definition, setDefinition] = useState(DEFAULT_PASS_DEFINITION)
  const [roleMode, setRoleMode] = useState<'create' | 'existing'>('create')
  const [roles, setRoles] = useState<RoleOption[]>([])
  const [existingRoleArn, setExistingRoleArn] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    void listExecutionRoles()
      .then((list) => {
        setRoles(list)
        setExistingRoleArn((cur) => cur || list[0]?.arn || '')
      })
      .catch(() => {
        setRoles([{ name: BASIC_SFN_ROLE_NAME, arn: '' }])
      })
  }, [])

  async function onCreate() {
    const smName = name.trim()
    if (!smName) {
      setError('State machine name is required')
      return
    }
    if (!definition.trim()) {
      setError('Definition is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const created = await createStateMachineFromForm({
        name: smName,
        definition,
        type: smType,
        roleMode,
        existingRoleArn: existingRoleArn || undefined,
      })
      navigate(
        `/stepfunctions/state-machines/${encodeURIComponent(created.name)}`,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create state machine</h1>
      <p className="aws-desc">
        Define a Standard or Express workflow with an ASL definition and an
        execution role. LocalEmu accepts Pass (and other) states — Workflow
        Studio stays out of scope.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Type</h2>
          <ul className="aws-radio-list">
            <li>
              <label>
                <input
                  type="radio"
                  name="smType"
                  value="STANDARD"
                  checked={smType === 'STANDARD'}
                  onChange={() => setSmType('STANDARD')}
                />
                <span>
                  <strong>Standard</strong>
                  <span className="sub">
                    Exactly-once · durable executions (LocalEmu default).
                  </span>
                </span>
              </label>
            </li>
            <li>
              <label>
                <input
                  type="radio"
                  name="smType"
                  value="EXPRESS"
                  checked={smType === 'EXPRESS'}
                  onChange={() => setSmType('EXPRESS')}
                />
                <span>
                  <strong>Express</strong>
                  <span className="sub">
                    At-least-once · short-lived / high-volume.
                  </span>
                </span>
              </label>
            </li>
          </ul>
        </div>
      </section>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="sm-name">
                State machine name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="sm-name"
                name="name"
                type="text"
                autoComplete="off"
                placeholder="MyStateMachine"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="sfn-create-name"
              />
              <p className="aws-hint">
                1–80 characters. Letters, numbers, hyphens, and underscores.
              </p>
            </div>

            <div className="aws-field">
              <label className="aws-label">Execution role</label>
              <ul className="aws-radio-list">
                <li>
                  <label>
                    <input
                      type="radio"
                      name="roleMode"
                      value="create"
                      checked={roleMode === 'create'}
                      onChange={() => setRoleMode('create')}
                    />
                    <span>
                      <strong>Create a new role</strong>
                      <span className="sub">
                        Creates <code>{BASIC_SFN_ROLE_NAME}</code> trusted by{' '}
                        <code>states.amazonaws.com</code> if missing.
                      </span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="roleMode"
                      value="existing"
                      checked={roleMode === 'existing'}
                      onChange={() => setRoleMode('existing')}
                    />
                    <span>
                      <strong>Use an existing role</strong>
                      <span className="sub">Pick an IAM role ARN.</span>
                    </span>
                  </label>
                </li>
              </ul>
              {roleMode === 'existing' ? (
                <select
                  className="aws-select aws-input"
                  style={{ marginTop: 8 }}
                  value={existingRoleArn}
                  onChange={(e) => setExistingRoleArn(e.target.value)}
                  data-testid="sfn-create-role"
                >
                  {roles.map((r) => (
                    <option key={r.arn || r.name} value={r.arn || r.name}>
                      {r.name}
                    </option>
                  ))}
                </select>
              ) : null}
            </div>

            <div className="aws-field">
              <label className="aws-label">Logging</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure logging…
              </button>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Definition</h2>
            <div
              className="aws-choice-row"
              role="group"
              aria-label="Definition source"
            >
              <button
                type="button"
                className="aws-choice is-selected"
                aria-pressed="true"
              >
                <strong>Write ASL</strong>
                <span>Paste Amazon States Language JSON.</span>
              </button>
              <button
                type="button"
                className="aws-choice"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                <strong>Workflow Studio</strong>
                <span>Visual designer (not in LocalEmu console yet).</span>
              </button>
            </div>
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label" htmlFor="sm-definition">
                Definition (JSON) <span className="req">*</span>
              </label>
              <textarea
                className="aws-input aws-mono"
                id="sm-definition"
                name="definition"
                rows={14}
                spellCheck={false}
                value={definition}
                onChange={(e) => setDefinition(e.target.value)}
                data-testid="sfn-create-definition"
                style={{
                  width: '100%',
                  fontFamily: 'var(--aws-mono, ui-monospace, monospace)',
                  fontSize: 12,
                  lineHeight: 1.45,
                  resize: 'vertical',
                }}
              />
              <p className="aws-hint">
                Must be valid ASL JSON. Pass + Standard is the LocalEmu happy
                path.
              </p>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/stepfunctions">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="sfn-create-submit"
        >
          {busy ? 'Creating…' : 'Create'}
        </button>
      </div>
    </>
  )
}
