import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import {
  describeClusters,
  describeServices,
  describeTasks,
  listClusterArns,
  listServiceArns,
  listTaskArns,
  type Cluster,
  type Service,
  type Task,
} from '../lib/ecs'

function clusterName(arn: string): string {
  const parts = arn.split('/')
  return parts[parts.length - 1] || arn
}

function ClustersList() {
  const navigate = useNavigate()
  const [clusters, setClusters] = useState<Cluster[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const arns = await listClusterArns()
      setClusters(await describeClusters(arns))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return (
    <>
      <div className="crumbs">
        <span>Elastic Container Service</span>
        <span className="crumbs-sep">/</span>
        <span>Clusters</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          Clusters ({loading ? '…' : clusters.length})
        </h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      <p className="page-lead">
        Create via <code>./bin/ecs-smoke.sh</code> / terraform example.
      </p>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : clusters.length === 0 ? (
          <div className="empty">
            <strong>No clusters</strong>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th>Cluster name</th>
                <th>Status</th>
                <th>Active services</th>
                <th>Running tasks</th>
              </tr>
            </thead>
            <tbody>
              {clusters.map((c) => {
                const name = c.clusterName ?? clusterName(c.clusterArn ?? '')
                return (
                  <tr key={c.clusterArn ?? name}>
                    <td>
                      <button
                        type="button"
                        className="btn-link"
                        onClick={() =>
                          navigate(`/ecs/clusters/${encodeURIComponent(name)}`)
                        }
                      >
                        {name}
                      </button>
                    </td>
                    <td>{c.status ?? '—'}</td>
                    <td>{c.activeServicesCount ?? '—'}</td>
                    <td>{c.runningTasksCount ?? '—'}</td>
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

function ClusterDetail({ name }: { name: string }) {
  const [cluster, setCluster] = useState<Cluster | null>(null)
  const [services, setServices] = useState<Service[]>([])
  const [tasks, setTasks] = useState<Task[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [cs, serviceArns, taskArns] = await Promise.all([
        describeClusters([name]),
        listServiceArns(name),
        listTaskArns(name),
      ])
      setCluster(cs[0] ?? null)
      const [svcs, tks] = await Promise.all([
        describeServices(name, serviceArns),
        describeTasks(name, taskArns),
      ])
      setServices(svcs)
      setTasks(tks)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return (
    <>
      <div className="crumbs">
        <Link to="/ecs">ECS</Link>
        <span className="crumbs-sep">/</span>
        <Link to="/ecs">Clusters</Link>
        <span className="crumbs-sep">/</span>
        <span>{name}</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">{name}</h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel cfn-overview">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : (
          <>
            <section>
              <h2 className="cfn-section-title">Overview</h2>
              <dl className="cfn-kv">
                <div>
                  <dt>Status</dt>
                  <dd>{cluster?.status ?? '—'}</dd>
                </div>
                <div>
                  <dt>ARN</dt>
                  <dd>
                    <code className="cfn-arn">{cluster?.clusterArn ?? '—'}</code>
                  </dd>
                </div>
              </dl>
            </section>
            <section>
              <h2 className="cfn-section-title">Services</h2>
              {services.length === 0 ? (
                <p className="cfn-muted">No services</p>
              ) : (
                <table className="data">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Status</th>
                      <th>Desired</th>
                      <th>Running</th>
                    </tr>
                  </thead>
                  <tbody>
                    {services.map((s) => (
                      <tr key={s.serviceArn ?? s.serviceName}>
                        <td>{s.serviceName ?? '—'}</td>
                        <td>{s.status ?? '—'}</td>
                        <td>{s.desiredCount ?? '—'}</td>
                        <td>{s.runningCount ?? '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </section>
            <section>
              <h2 className="cfn-section-title">Tasks</h2>
              {tasks.length === 0 ? (
                <p className="cfn-muted">No tasks</p>
              ) : (
                <table className="data">
                  <thead>
                    <tr>
                      <th>Task</th>
                      <th>Last status</th>
                      <th>Desired</th>
                      <th>Launch type</th>
                    </tr>
                  </thead>
                  <tbody>
                    {tasks.map((t) => {
                      const arn = t.taskArn ?? ''
                      const short = arn.split('/').pop() ?? arn
                      return (
                        <tr key={arn}>
                          <td>
                            <code>{short}</code>
                          </td>
                          <td>{t.lastStatus ?? '—'}</td>
                          <td>{t.desiredStatus ?? '—'}</td>
                          <td className="cfn-muted">{t.launchType ?? '—'}</td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              )}
            </section>
          </>
        )}
      </div>
    </>
  )
}

export function EcsClustersPage() {
  const { name } = useParams<{ name?: string }>()
  if (name) {
    return <ClusterDetail name={decodeURIComponent(name)} />
  }
  return <ClustersList />
}
