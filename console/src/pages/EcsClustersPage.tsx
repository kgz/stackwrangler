import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton, TO_IMPLEMENT } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  FilterHeader,
  Kv,
  ListCard,
  Mono,
  Notices,
  PlainHeader,
  Section,
  SelectCell,
  SelectHeader,
  SortHeader,
  StatusBadge,
} from '../components/ServiceUi'
import {
  containerPrivateIp,
  createCluster,
  describeClusters,
  describeServices,
  describeTask,
  describeTasks,
  formatTaskTime,
  listClusterArns,
  listServiceArns,
  listTaskArns,
  taskDefinitionFamily,
  taskShortId,
  type Cluster,
  type Service,
  type Task,
} from '../lib/ecs'

function clusterName(arn: string): string {
  const parts = arn.split('/')
  return parts[parts.length - 1] || arn
}

function ClustersList() {
  const [clusters, setClusters] = useState<Cluster[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
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

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return clusters
    return clusters.filter((c) =>
      (c.clusterName ?? '').toLowerCase().includes(q),
    )
  }, [clusters, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Clusters"
      desc={
        <>
          An Amazon ECS cluster is a logical grouping of tasks or services.
          Run tasks / register definitions via{' '}
          <code>./smokes/compute/ecs-smoke.sh</code> or terraform.
        </>
      }
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Delete Cluster</DeadButton>
          <div className="spacer" />
          <Link className="btn btn-primary" to="/ecs/create">
            Create Cluster
          </Link>
        </>
      }
      placeholder="Filter clusters"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="ecs-clusters-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Cluster name</SortHeader>
            <FilterHeader>Status</FilterHeader>
            <SortHeader>Registered container instances</SortHeader>
            <SortHeader>Services</SortHeader>
            <SortHeader>Tasks running</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={6}
              loading={loading}
              loadingText="Loading clusters…"
              title="No clusters"
            />
          ) : (
            filtered.map((c) => {
              const name = c.clusterName ?? clusterName(c.clusterArn ?? '')
              const isSelected = selected === name
              return (
                <tr
                  key={c.clusterArn ?? name}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(name)}
                >
                  <SelectCell
                    name="selected-cluster"
                    id={name}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[c.clusterArn, name]}>
                      <Link
                        to={`/ecs/clusters/${encodeURIComponent(name)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {name}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    <StatusBadge status={c.status} />
                  </td>
                  <td>{c.registeredContainerInstancesCount ?? 0}</td>
                  <td>{c.activeServicesCount ?? 0}</td>
                  <td>{c.runningTasksCount ?? 0}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}

function CreateCluster() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const clusterNameValue = name.trim()
    if (!clusterNameValue) {
      setError('Cluster name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createCluster(clusterNameValue)
      navigate(`/ecs/clusters/${encodeURIComponent(clusterNameValue)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create cluster</h1>
      <p className="aws-desc">
        Create an empty ECS cluster. LocalEmu accepts a cluster name only —
        capacity providers, Container Insights, and VPC settings stay
        CLI/terraform for now.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Cluster configuration</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="cluster-name">
                Cluster name <span className="req" aria-hidden="true">*</span>
              </label>
              <input
                className="aws-input"
                id="cluster-name"
                name="clusterName"
                type="text"
                autoComplete="off"
                placeholder="my-cluster"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="ecs-cluster-name"
              />
              <p className="aws-hint">
                Up to 255 letters, numbers, hyphens, and underscores.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label">Infrastructure</label>
              <ul className="aws-radio-list">
                <li>
                  <label>
                    <input
                      type="radio"
                      name="infra"
                      value="fargate"
                      defaultChecked
                    />
                    <span>
                      <strong>AWS Fargate (serverless)</strong>
                      <span className="sub">
                        Default LocalEmu launch type for run-task / services.
                      </span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="infra"
                      value="ec2"
                      disabled
                      title={TO_IMPLEMENT}
                    />
                    <span>
                      <strong>Amazon EC2 instances</strong>
                      <span className="sub">
                        Register container instances via CLI / smoke.
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
        <Link className="btn btn-normal" to="/ecs">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="ecs-create-submit"
        >
          {busy ? 'Creating…' : 'Create'}
        </button>
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
      <DetailHeader
        title={name}
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Actions ▾</DeadButton>
          </>
        }
        subtitle={cluster ? <StatusBadge status={cluster.status} /> : null}
      />
      <Notices error={error} />
      {loading ? (
        <p className="aws-desc">Loading…</p>
      ) : (
        <>
          <Section title="Overview">
            <Kv
              rows={[
                ['Status', <StatusBadge key="st" status={cluster?.status} />],
                [
                  'ARN',
                  <ResourceLabel
                    key="arn"
                    ids={[cluster?.clusterArn, name]}
                    detail
                  >
                    <Mono>{cluster?.clusterArn ?? '—'}</Mono>
                  </ResourceLabel>,
                ],
                ['Active services', cluster?.activeServicesCount ?? 0],
                ['Running tasks', cluster?.runningTasksCount ?? 0],
                ['Pending tasks', cluster?.pendingTasksCount ?? 0],
                [
                  'Registered container instances',
                  cluster?.registeredContainerInstancesCount ?? 0,
                ],
              ]}
            />
          </Section>
          <Section title="Services" spaced>
            <div className="aws-table-wrap">
              <table className="aws-table" data-testid="ecs-services-table">
                <thead>
                  <tr>
                    <PlainHeader>Service name</PlainHeader>
                    <PlainHeader>Status</PlainHeader>
                    <PlainHeader>Task definition</PlainHeader>
                    <PlainHeader>Launch type</PlainHeader>
                    <PlainHeader>Desired tasks</PlainHeader>
                    <PlainHeader>Running tasks</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {services.length === 0 ? (
                    <EmptyRow
                      colSpan={6}
                      loading={false}
                      loadingText=""
                      title="No services"
                    />
                  ) : (
                    services.map((s) => (
                      <tr key={s.serviceArn ?? s.serviceName}>
                        <td>
                          <ResourceLabel ids={[s.serviceArn, s.serviceName]}>
                            {s.serviceName ?? '—'}
                          </ResourceLabel>
                        </td>
                        <td>
                          <StatusBadge status={s.status} />
                        </td>
                        <td>
                          <Mono>
                            {taskDefinitionFamily(s.taskDefinition)}
                          </Mono>
                        </td>
                        <td>{s.launchType ?? '—'}</td>
                        <td>{s.desiredCount ?? '—'}</td>
                        <td>{s.runningCount ?? '—'}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </Section>
          <Section title="Tasks" spaced>
            <div className="aws-table-wrap">
              <table className="aws-table" data-testid="ecs-tasks-table">
                <thead>
                  <tr>
                    <PlainHeader>Task</PlainHeader>
                    <PlainHeader>Last status</PlainHeader>
                    <PlainHeader>Desired status</PlainHeader>
                    <PlainHeader>Task definition</PlainHeader>
                    <PlainHeader>Launch type</PlainHeader>
                    <PlainHeader>Started at</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {tasks.length === 0 ? (
                    <EmptyRow
                      colSpan={6}
                      loading={false}
                      loadingText=""
                      title="No tasks"
                    />
                  ) : (
                    tasks.map((t) => {
                      const arn = t.taskArn ?? ''
                      const short = taskShortId(arn)
                      return (
                        <tr key={arn}>
                          <td>
                            <ResourceLabel ids={[arn]}>
                              <Link
                                to={`/ecs/clusters/${encodeURIComponent(name)}/tasks/${encodeURIComponent(short)}`}
                              >
                                <Mono>{short}</Mono>
                              </Link>
                            </ResourceLabel>
                          </td>
                          <td>
                            <StatusBadge status={t.lastStatus} />
                          </td>
                          <td>{t.desiredStatus ?? '—'}</td>
                          <td>
                            <Mono>
                              {taskDefinitionFamily(t.taskDefinitionArn)}
                            </Mono>
                          </td>
                          <td>{t.launchType ?? '—'}</td>
                          <td>{formatTaskTime(t.startedAt)}</td>
                        </tr>
                      )
                    })
                  )}
                </tbody>
              </table>
            </div>
          </Section>
        </>
      )}
      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to="/ecs">Back to clusters</Link>
      </p>
    </>
  )
}

function TaskDetail({
  cluster,
  taskId,
}: {
  cluster: string
  taskId: string
}) {
  const [task, setTask] = useState<Task | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeTask(cluster, taskId)
      setTask(found)
      if (!found) {
        setError(`Task ${taskId} not found in cluster ${cluster}`)
      }
    } catch (err) {
      setTask(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [cluster, taskId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const short = taskShortId(task?.taskArn ?? taskId)
  const containers = task?.containers ?? []

  return (
    <>
      <DetailHeader
        title={
          <ResourceLabel ids={[task?.taskArn, short]} detail>
            <Mono>{short}</Mono>
          </ResourceLabel>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Stop</DeadButton>
          </>
        }
        subtitle={
          task ? (
            <>
              <StatusBadge status={task.lastStatus} />
              <span>
                Cluster {cluster} · {task.launchType ?? '—'}
              </span>
            </>
          ) : null
        }
      />
      <Notices error={error} />
      {loading ? (
        <p className="aws-desc">Loading…</p>
      ) : task ? (
        <>
          <Section title="Configuration">
            <Kv
              rows={[
                [
                  'Task ARN',
                  <Mono key="arn">{task.taskArn ?? '—'}</Mono>,
                ],
                [
                  'Last status',
                  <StatusBadge key="ls" status={task.lastStatus} />,
                ],
                ['Desired status', task.desiredStatus ?? '—'],
                ['Launch type', task.launchType ?? '—'],
                [
                  'Task definition',
                  <Mono key="td">
                    {taskDefinitionFamily(task.taskDefinitionArn)}
                  </Mono>,
                ],
                ['Group', task.group ?? '—'],
                ['Platform version', task.platformVersion ?? '—'],
                [
                  'CPU / Memory',
                  `${task.cpu ?? '—'} / ${task.memory ?? '—'}`,
                ],
                ['Started at', formatTaskTime(task.startedAt)],
                [
                  'Stopped reason',
                  task.stoppedReason?.trim() ? task.stoppedReason : '—',
                ],
              ]}
            />
          </Section>
          <Section title="Containers" spaced>
            <div className="aws-table-wrap">
              <table
                className="aws-table"
                data-testid="ecs-containers-table"
              >
                <thead>
                  <tr>
                    <PlainHeader>Name</PlainHeader>
                    <PlainHeader>Last status</PlainHeader>
                    <PlainHeader>Image</PlainHeader>
                    <PlainHeader>Exit code</PlainHeader>
                    <PlainHeader>Network</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {containers.length === 0 ? (
                    <EmptyRow
                      colSpan={5}
                      loading={false}
                      loadingText=""
                      title="No containers"
                    />
                  ) : (
                    containers.map((c) => (
                      <tr key={c.name ?? c.containerArn}>
                        <td>{c.name ?? '—'}</td>
                        <td>
                          <StatusBadge status={c.lastStatus} />
                        </td>
                        <td>
                          <Mono>{c.image ?? '—'}</Mono>
                        </td>
                        <td>
                          {c.exitCode === undefined || c.exitCode === null
                            ? '—'
                            : c.exitCode}
                        </td>
                        <td>{containerPrivateIp(c)}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </Section>
          <Section title="Logs" spaced>
            <p className="aws-desc" data-testid="ecs-logs-stub">
              Container log streaming is not wired in LocalEmu console yet.
              Use <code>aws logs</code> / CloudWatch Log groups when the task
              definition sets <code>awslogs</code>, or inspect the Docker
              container on the host.
            </p>
            <DeadButton>View in CloudWatch Logs</DeadButton>
          </Section>
        </>
      ) : null}
      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to={`/ecs/clusters/${encodeURIComponent(cluster)}`}>
          Back to cluster
        </Link>
      </p>
    </>
  )
}

export function EcsClustersPage() {
  const { name, taskId } = useParams<{ name?: string; taskId?: string }>()
  if (name && taskId) {
    return (
      <TaskDetail
        cluster={decodeURIComponent(name)}
        taskId={decodeURIComponent(taskId)}
      />
    )
  }
  if (name) {
    return <ClusterDetail name={decodeURIComponent(name)} />
  }
  return <ClustersList />
}

export function EcsCreateClusterPage() {
  return <CreateCluster />
}
