import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import {
  deleteDbInstance,
  describeDbInstance,
  listDbInstances,
  type DBInstance,
} from '../lib/rds'

function endpointLabel(db: DBInstance): string {
  const a = db.Endpoint?.Address
  const p = db.Endpoint?.Port
  if (!a) return '—'
  if (p === undefined || p === null) return a
  return `${a}:${p}`
}

function connectHint(db: DBInstance): string {
  const host = db.Endpoint?.Address ?? '127.0.0.1'
  const port = db.Endpoint?.Port ?? 5432
  const user = db.MasterUsername ?? 'awsbox'
  const name = db.DBName ?? 'awsbox'
  const h =
    host.includes('rds.amazonaws.com') || host === 'localhost'
      ? '127.0.0.1'
      : host
  return `psql -h ${h} -p ${port} -U ${user} -d ${name}`
}

function InstancesList() {
  const navigate = useNavigate()
  const [dbs, setDbs] = useState<DBInstance[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setDbs(await listDbInstances())
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onDelete() {
    if (!selected) return
    setBusy(true)
    setError(null)
    try {
      await deleteDbInstance(selected)
      setToast(`Delete started for ${selected}`)
      setSelected(null)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <div className="crumbs">
        <span>RDS</span>
        <span className="crumbs-sep">/</span>
        <span>Databases</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          Databases ({loading ? '…' : dbs.length})
        </h1>
        <div className="cfn-page-actions">
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn"
            disabled={!selected || busy}
            onClick={() => void onDelete()}
          >
            Delete
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled
            title="Use ./bin/rds-smoke.sh"
          >
            Create database
          </button>
        </div>
      </div>
      <p className="page-lead">
        Docker-backed instances when <code>RDS_DOCKER_BACKEND=1</code>. Create
        via <code>./bin/rds-smoke.sh</code>.
      </p>
      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}
      <div className="panel">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : dbs.length === 0 ? (
          <div className="empty">
            <strong>No databases</strong>
            Run <code>./bin/rds-smoke.sh</code> (keep with{' '}
            <code>AWSBOX_RDS_KEEP=1</code> to inspect).
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th className="col-check" aria-label="Select" />
                <th>DB identifier</th>
                <th>Status</th>
                <th>Engine</th>
                <th>Endpoint</th>
              </tr>
            </thead>
            <tbody>
              {dbs.map((db) => {
                const id = db.DBInstanceIdentifier ?? ''
                return (
                  <tr
                    key={id}
                    className={selected === id ? 'row-selected' : undefined}
                    onClick={() => setSelected(id)}
                  >
                    <td className="col-check">
                      <input
                        type="radio"
                        name="rds"
                        checked={selected === id}
                        aria-label={`Select ${id}`}
                        onChange={() => setSelected(id)}
                      />
                    </td>
                    <td>
                      <ResourceLabel ids={[id, db.DBInstanceArn]}>
                        <button
                          type="button"
                          className="btn-link"
                          onClick={(e) => {
                            e.stopPropagation()
                            navigate(`/rds/databases/${encodeURIComponent(id)}`)
                          }}
                        >
                          {id}
                        </button>
                      </ResourceLabel>
                    </td>
                    <td>{db.DBInstanceStatus ?? '—'}</td>
                    <td className="cfn-muted">
                      {db.Engine ?? '—'} {db.EngineVersion ?? ''}
                    </td>
                    <td className="cfn-muted">{endpointLabel(db)}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}

function InstanceDetail({ id }: { id: string }) {
  const [db, setDb] = useState<DBInstance | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setDb(await describeDbInstance(id))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [id])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return (
    <>
      <div className="crumbs">
        <Link to="/rds">RDS</Link>
        <span className="crumbs-sep">/</span>
        <Link to="/rds">Databases</Link>
        <span className="crumbs-sep">/</span>
        <span>{id}</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          <ResourceLabel ids={[id, db?.DBInstanceArn]} detail>
            {id}
          </ResourceLabel>
        </h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel cfn-overview">
        {loading || !db ? (
          <div className="cfn-loading">Loading…</div>
        ) : (
          <section>
            <h2 className="cfn-section-title">Connectivity</h2>
            <dl className="cfn-kv">
              <div>
                <dt>Status</dt>
                <dd>{db.DBInstanceStatus ?? '—'}</dd>
              </div>
              <div>
                <dt>Engine</dt>
                <dd>
                  {db.Engine ?? '—'} {db.EngineVersion ?? ''}
                </dd>
              </div>
              <div>
                <dt>Endpoint</dt>
                <dd>
                  <code>{endpointLabel(db)}</code>
                </dd>
              </div>
              <div>
                <dt>Master username</dt>
                <dd>{db.MasterUsername ?? '—'}</dd>
              </div>
              <div>
                <dt>DB name</dt>
                <dd>{db.DBName ?? '—'}</dd>
              </div>
              <div>
                <dt>Connect</dt>
                <dd>
                  <code>{connectHint(db)}</code>
                </dd>
              </div>
            </dl>
          </section>
        )}
      </div>
    </>
  )
}

export function RdsInstancesPage() {
  const { id } = useParams<{ id?: string }>()
  if (id) {
    return <InstanceDetail id={decodeURIComponent(id)} />
  }
  return <InstancesList />
}
