import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { createDbInstance } from '../lib/rds'

type Engine = 'postgres' | 'mysql'

const ENGINE_VERSIONS: Record<Engine, string[]> = {
  postgres: ['16.3', '15.8'],
  mysql: ['8.0', '8.0.39'],
}

export function RdsCreateDatabasePage() {
  const navigate = useNavigate()
  const [engine, setEngine] = useState<Engine>('postgres')
  const [identifier, setIdentifier] = useState('')
  const [engineVersion, setEngineVersion] = useState('16.3')
  const [instanceClass, setInstanceClass] = useState('db.t3.micro')
  const [allocatedStorage, setAllocatedStorage] = useState('20')
  const [dbName, setDbName] = useState('stackwrangler')
  const [masterUsername, setMasterUsername] = useState('stackwrangler')
  const [masterPassword, setMasterPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const versions = useMemo(() => ENGINE_VERSIONS[engine], [engine])

  function pickEngine(next: Engine) {
    setEngine(next)
    const first = ENGINE_VERSIONS[next][0]
    setEngineVersion(first)
  }

  async function onCreate() {
    const id = identifier.trim()
    if (!id) {
      setError('DB instance identifier is required')
      return
    }
    if (!masterUsername.trim()) {
      setError('Master username is required')
      return
    }
    if (!masterPassword) {
      setError('Master password is required')
      return
    }
    if (masterPassword !== confirmPassword) {
      setError('Passwords do not match')
      return
    }
    const storage = Number(allocatedStorage)
    if (!Number.isFinite(storage) || storage < 20) {
      setError('Allocated storage must be at least 20 GiB')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createDbInstance({
        identifier: id,
        engine,
        engineVersion,
        instanceClass,
        allocatedStorage: storage,
        masterUsername: masterUsername.trim(),
        masterUserPassword: masterPassword,
        dbName: dbName.trim() || undefined,
      })
      navigate(`/rds/databases/${encodeURIComponent(id)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create database</h1>
      <p className="aws-desc">
        Standard create for Docker-backed Postgres or MySQL when{' '}
        <code>RDS_DOCKER_BACKEND=1</code>. Aurora clusters stay on{' '}
        <code>./smokes/data/rds-mysql-smoke.sh</code>.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Choose a database creation method</h2>
          <div
            className="aws-choice-row"
            role="group"
            aria-label="Create method"
          >
            <button
              type="button"
              className="aws-choice is-selected"
              aria-pressed="true"
            >
              <span>
                <strong>Standard create</strong>
                <span>Full control of engine, class, storage, and credentials.</span>
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
                <strong>Easy create</strong>
                <span>Use recommended best-practice options.</span>
              </span>
            </button>
          </div>
        </div>
      </section>

      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body">
          <h2 className="aws-section-title">Engine options</h2>
          <div className="aws-choice-row" role="group" aria-label="Engine">
            <button
              type="button"
              className={`aws-choice${engine === 'postgres' ? ' is-selected' : ''}`}
              aria-pressed={engine === 'postgres'}
              onClick={() => pickEngine('postgres')}
            >
              <span>
                <strong>PostgreSQL</strong>
                <span>Docker Postgres via LocalEmu.</span>
              </span>
            </button>
            <button
              type="button"
              className={`aws-choice${engine === 'mysql' ? ' is-selected' : ''}`}
              aria-pressed={engine === 'mysql'}
              onClick={() => pickEngine('mysql')}
            >
              <span>
                <strong>MySQL</strong>
                <span>Docker MySQL via LocalEmu.</span>
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
                <strong>Amazon Aurora</strong>
                <span>CLI / Aurora MySQL smoke only.</span>
              </span>
            </button>
          </div>
        </div>
      </section>

      <section className="aws-card aws-card-flush" style={{ marginTop: 16 }}>
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Settings</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-id">
                DB instance identifier <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="db-id"
                data-testid="rds-create-id"
                value={identifier}
                onChange={(e) => setIdentifier(e.target.value)}
                autoComplete="off"
                placeholder="database-1"
              />
              <p className="aws-hint">
                1–63 characters. Letters, numbers, and hyphens. Must start with a
                letter.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-engine-version">
                Engine version <span className="req">*</span>
              </label>
              <select
                className="aws-select"
                id="db-engine-version"
                data-testid="rds-create-engine-version"
                value={engineVersion}
                onChange={(e) => setEngineVersion(e.target.value)}
                style={{ maxWidth: 480, width: '100%' }}
              >
                {versions.map((v) => (
                  <option key={v} value={v}>
                    {v}
                  </option>
                ))}
              </select>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-class">
                DB instance class
              </label>
              <select
                className="aws-select"
                id="db-class"
                data-testid="rds-create-class"
                value={instanceClass}
                onChange={(e) => setInstanceClass(e.target.value)}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option value="db.t3.micro">db.t3.micro</option>
                <option value="db.t3.small">db.t3.small</option>
                <option value="db.t4g.micro">db.t4g.micro</option>
              </select>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-storage">
                Allocated storage (GiB) <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="db-storage"
                data-testid="rds-create-storage"
                type="number"
                min={20}
                value={allocatedStorage}
                onChange={(e) => setAllocatedStorage(e.target.value)}
                style={{ maxWidth: 240 }}
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-name">
                Initial database name
              </label>
              <input
                className="aws-input"
                id="db-name"
                data-testid="rds-create-dbname"
                value={dbName}
                onChange={(e) => setDbName(e.target.value)}
                autoComplete="off"
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Credentials</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-user">
                Master username <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="db-user"
                data-testid="rds-create-user"
                value={masterUsername}
                onChange={(e) => setMasterUsername(e.target.value)}
                autoComplete="off"
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-pass">
                Master password <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="db-pass"
                data-testid="rds-create-password"
                type="password"
                value={masterPassword}
                onChange={(e) => setMasterPassword(e.target.value)}
                autoComplete="new-password"
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-pass2">
                Confirm password <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="db-pass2"
                data-testid="rds-create-password-confirm"
                type="password"
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
                autoComplete="new-password"
              />
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Connectivity</h2>
            <p className="aws-desc" style={{ marginBottom: 12 }}>
              VPC / subnet / security group pickers are not wired in this local
              subset.
            </p>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-vpc">
                Virtual private cloud (VPC)
              </label>
              <select
                className="aws-select"
                id="db-vpc"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option>Default VPC (local)</option>
              </select>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-subnet">
                DB subnet group
              </label>
              <select
                className="aws-select"
                id="db-subnet"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option>default-vpc-subnet-group</option>
              </select>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-sg">
                VPC security groups
              </label>
              <select
                className="aws-select"
                id="db-sg"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option>default</option>
              </select>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="db-multiaz">
                Multi-AZ deployment
              </label>
              <select
                className="aws-select"
                id="db-multiaz"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
                style={{ maxWidth: 480, width: '100%' }}
              >
                <option>No</option>
              </select>
            </div>
          </div>

          <div className="aws-form-actions">
            <Link className="btn btn-normal" to="/rds">
              Cancel
            </Link>
            <div className="spacer" style={{ flex: 1 }} />
            <button
              type="button"
              className="btn btn-primary"
              data-testid="rds-create-submit"
              disabled={busy}
              onClick={() => void onCreate()}
            >
              {busy ? 'Creating…' : 'Create database'}
            </button>
          </div>
        </div>
      </section>
    </>
  )
}
