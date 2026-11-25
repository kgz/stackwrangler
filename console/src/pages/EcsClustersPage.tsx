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
  awslogsTargetsForTask,
  containerPrivateIp,
  createCluster,
  createService,
  describeClusters,
  describeServices,
  describeTask,
  describeTaskDefinition,
  describeTasks,
  formatTaskTime,
  listClusterArns,
  listServiceArns,
  listTaskArns,
  parseCsvIds,
  runTask,
  stopTask,
  taskDefinitionFamily,
  taskShortId,
  type AwsLogsTarget,
  type Cluster,
  type Service,
  type Task,
} from '../lib/ecs'
import { filterLogEvents } from '../lib/logs'
import type { FilteredLogEvent } from '@aws-sdk/client-cloudwatch-logs'

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
            <Link
              className="btn btn-normal"
              to={`/ecs/clusters/${encodeURIComponent(name)}/run-task`}
              data-testid="ecs-run-task-link"
            >
              Run task
            </Link>
            <Link
              className="btn btn-primary"
              to={`/ecs/clusters/${encodeURIComponent(name)}/create-service`}
              data-testid="ecs-create-service-link"
            >
              Create service
            </Link>
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
  const [logsTargets, setLogsTargets] = useState<AwsLogsTarget[]>([])
  const [logEvents, setLogEvents] = useState<FilteredLogEvent[]>([])
  const [loading, setLoading] = useState(true)
  const [stopping, setStopping] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeTask(cluster, taskId)
      setTask(found)
      if (!found) {
        setLogsTargets([])
        setLogEvents([])
        setError(`Task ${taskId} not found in cluster ${cluster}`)
        return
      }
      const tdArn = found.taskDefinitionArn
      const td = tdArn ? await describeTaskDefinition(tdArn) : null
      const targets = awslogsTargetsForTask(td, found)
      setLogsTargets(targets)
      if (targets.length > 0) {
        const primary = targets[0]
        try {
          setLogEvents(
            await filterLogEvents({
              logGroupName: primary.logGroupName,
              logStreamNames: [primary.logStreamName],
              limit: 50,
            }),
          )
        } catch {
          setLogEvents(
            await filterLogEvents({
              logGroupName: primary.logGroupName,
              limit: 50,
            }),
          )
        }
      } else {
        setLogEvents([])
      }
    } catch (err) {
      setTask(null)
      setLogsTargets([])
      setLogEvents([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [cluster, taskId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onStop() {
    setStopping(true)
    setError(null)
    try {
      await stopTask(cluster, task?.taskArn ?? taskId)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setStopping(false)
    }
  }

  const short = taskShortId(task?.taskArn ?? taskId)
  const containers = task?.containers ?? []
  const primaryLogs = logsTargets[0]
  const stopped = (task?.lastStatus ?? '').toUpperCase() === 'STOPPED'

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
            <button
              type="button"
              className="btn btn-normal"
              disabled={stopping || !task || stopped}
              onClick={() => void onStop()}
              data-testid="ecs-stop-task"
            >
              {stopping ? 'Stopping…' : 'Stop'}
            </button>
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
            {primaryLogs ? (
              <>
                <p className="aws-desc" data-testid="ecs-logs-awslogs">
                  Container <Mono>{primaryLogs.containerName}</Mono> uses the{' '}
                  <code>awslogs</code> log driver. Events below come from
                  CloudWatch Logs when LocalEmu has received them; Docker host
                  logs remain available via the CLI.
                </p>
                <Kv
                  rows={[
                    [
                      'Log group',
                      <Mono key="lg">{primaryLogs.logGroupName}</Mono>,
                    ],
                    [
                      'Log stream',
                      <Mono key="ls">{primaryLogs.logStreamName}</Mono>,
                    ],
                  ]}
                />
                <p style={{ marginTop: 12 }}>
                  <Link
                    className="btn btn-normal"
                    to={`/logs/log-groups/${encodeURIComponent(primaryLogs.logGroupName)}`}
                    data-testid="ecs-view-logs"
                  >
                    View in CloudWatch Logs
                  </Link>
                </p>
                <div
                  className="aws-table-wrap"
                  style={{ marginTop: 12 }}
                  data-testid="ecs-log-events"
                >
                  <table className="aws-table">
                    <thead>
                      <tr>
                        <PlainHeader>Timestamp</PlainHeader>
                        <PlainHeader>Message</PlainHeader>
                      </tr>
                    </thead>
                    <tbody>
                      {logEvents.length === 0 ? (
                        <EmptyRow
                          colSpan={2}
                          loading={false}
                          loadingText=""
                          title="No log events yet"
                        />
                      ) : (
                        logEvents.map((ev, i) => (
                          <tr key={`${ev.eventId ?? i}-${ev.timestamp ?? i}`}>
                            <td>
                              <Mono>
                                {ev.timestamp
                                  ? new Date(ev.timestamp).toISOString()
                                  : '—'}
                              </Mono>
                            </td>
                            <td>
                              <Mono>{ev.message ?? ''}</Mono>
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                </div>
              </>
            ) : (
              <>
                <p className="aws-desc" data-testid="ecs-logs-stub">
                  No <code>awslogs</code> logConfiguration on this task
                  definition. Use Docker logs on the host, or register a task
                  definition with the awslogs driver and open CloudWatch Log
                  groups.
                </p>
                <DeadButton>View in CloudWatch Logs</DeadButton>
              </>
            )}
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

function NetworkFields({
  subnets,
  securityGroups,
  onSubnets,
  onSecurityGroups,
}: {
  subnets: string
  securityGroups: string
  onSubnets: (v: string) => void
  onSecurityGroups: (v: string) => void
}) {
  return (
    <>
      <div className="aws-field">
        <label className="aws-label" htmlFor="ecs-subnets">
          Subnet IDs
        </label>
        <input
          className="aws-input"
          id="ecs-subnets"
          type="text"
          autoComplete="off"
          placeholder="subnet-… (comma-separated; required for awsvpc/Fargate)"
          value={subnets}
          onChange={(e) => onSubnets(e.target.value)}
          data-testid="ecs-subnets"
        />
        <p className="aws-hint">
          Optional for bridge/host task definitions. Fargate / awsvpc needs at
          least one subnet.
        </p>
      </div>
      <div className="aws-field">
        <label className="aws-label" htmlFor="ecs-security-groups">
          Security group IDs
        </label>
        <input
          className="aws-input"
          id="ecs-security-groups"
          type="text"
          autoComplete="off"
          placeholder="sg-… (comma-separated)"
          value={securityGroups}
          onChange={(e) => onSecurityGroups(e.target.value)}
          data-testid="ecs-security-groups"
        />
      </div>
    </>
  )
}

function LaunchTypeRadios() {
  return (
    <div className="aws-field">
      <label className="aws-label">App environment</label>
      <ul className="aws-radio-list">
        <li>
          <label>
            <input
              type="radio"
              name="app-environment"
              value="fargate"
              defaultChecked
              data-testid="ecs-launch-fargate"
            />
            <span>
              <strong>AWS Fargate</strong>
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
              name="app-environment"
              value="ec2"
              disabled
              title={TO_IMPLEMENT}
              data-testid="ecs-launch-ec2"
            />
            <span>
              <strong>Amazon EC2</strong>
              <span className="sub">
                Register container instances via CLI / smoke.
              </span>
            </span>
          </label>
        </li>
      </ul>
    </div>
  )
}

function RunTaskForm({ cluster }: { cluster: string }) {
  const navigate = useNavigate()
  const [taskDefinition, setTaskDefinition] = useState('')
  const [subnets, setSubnets] = useState('')
  const [securityGroups, setSecurityGroups] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onRun() {
    const td = taskDefinition.trim()
    if (!td) {
      setError('Task definition is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const subnetIds = parseCsvIds(subnets)
      const task = await runTask({
        cluster,
        taskDefinition: td,
        launchType: 'FARGATE',
        network:
          subnetIds.length > 0
            ? {
                subnetIds,
                securityGroupIds: parseCsvIds(securityGroups),
              }
            : undefined,
      })
      const short = taskShortId(task.taskArn)
      navigate(
        `/ecs/clusters/${encodeURIComponent(cluster)}/tasks/${encodeURIComponent(short)}`,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Run task</h1>
      <p className="aws-desc">
        Start a standalone task on cluster <Mono>{cluster}</Mono>. Calls
        LocalEmu <code>RunTask</code> with launch type Fargate.
      </p>
      <Notices error={error} />
      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Task configuration</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="run-task-definition">
                Task definition <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="run-task-definition"
                type="text"
                autoComplete="off"
                placeholder="family:revision"
                value={taskDefinition}
                onChange={(e) => setTaskDefinition(e.target.value)}
                data-testid="ecs-run-task-definition"
              />
              <p className="aws-hint">
                Family and optional revision (e.g. <code>my-app:3</code>).
              </p>
            </div>
            <LaunchTypeRadios />
            <NetworkFields
              subnets={subnets}
              securityGroups={securityGroups}
              onSubnets={setSubnets}
              onSecurityGroups={setSecurityGroups}
            />
          </div>
        </div>
      </section>
      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link
          className="btn btn-normal"
          to={`/ecs/clusters/${encodeURIComponent(cluster)}`}
        >
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onRun()}
          data-testid="ecs-run-submit"
        >
          {busy ? 'Running…' : 'Run'}
        </button>
      </div>
    </>
  )
}

function CreateServiceForm({ cluster }: { cluster: string }) {
  const navigate = useNavigate()
  const [serviceName, setServiceName] = useState('')
  const [taskDefinition, setTaskDefinition] = useState('')
  const [desiredCount, setDesiredCount] = useState('1')
  const [subnets, setSubnets] = useState('')
  const [securityGroups, setSecurityGroups] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const name = serviceName.trim()
    const td = taskDefinition.trim()
    const count = Math.floor(Number(desiredCount))
    if (!name) {
      setError('Service name is required')
      return
    }
    if (!td) {
      setError('Task definition is required')
      return
    }
    if (!Number.isFinite(count) || count < 0) {
      setError('Desired tasks must be a non-negative integer')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const subnetIds = parseCsvIds(subnets)
      await createService({
        cluster,
        serviceName: name,
        taskDefinition: td,
        desiredCount: count,
        launchType: 'FARGATE',
        network:
          subnetIds.length > 0
            ? {
                subnetIds,
                securityGroupIds: parseCsvIds(securityGroups),
              }
            : undefined,
      })
      navigate(`/ecs/clusters/${encodeURIComponent(cluster)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create service</h1>
      <p className="aws-desc">
        Configure a service on cluster <Mono>{cluster}</Mono>. Thin LocalEmu
        subset: name, task definition, desired count, and Fargate.
      </p>
      <Notices error={error} />
      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Service configuration</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="service-name">
                Service name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="service-name"
                type="text"
                autoComplete="off"
                placeholder="my-service"
                value={serviceName}
                onChange={(e) => setServiceName(e.target.value)}
                data-testid="ecs-service-name"
              />
              <p className="aws-hint">Up to 255 letters, numbers, and hyphens.</p>
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="service-task-definition">
                Task definition <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="service-task-definition"
                type="text"
                autoComplete="off"
                placeholder="family:revision"
                value={taskDefinition}
                onChange={(e) => setTaskDefinition(e.target.value)}
                data-testid="ecs-service-task-definition"
              />
            </div>
            <div className="aws-field">
              <label className="aws-label" htmlFor="desired-count">
                Desired tasks <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="desired-count"
                type="number"
                min={0}
                max={100}
                step={1}
                value={desiredCount}
                onChange={(e) => setDesiredCount(e.target.value)}
                data-testid="ecs-desired-count"
              />
            </div>
            <LaunchTypeRadios />
            <NetworkFields
              subnets={subnets}
              securityGroups={securityGroups}
              onSubnets={setSubnets}
              onSecurityGroups={setSecurityGroups}
            />
          </div>
        </div>
      </section>
      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link
          className="btn btn-normal"
          to={`/ecs/clusters/${encodeURIComponent(cluster)}`}
        >
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="ecs-create-service-submit"
        >
          {busy ? 'Creating…' : 'Create'}
        </button>
      </div>
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

export function EcsRunTaskPage() {
  const { name } = useParams<{ name?: string }>()
  if (!name) return <p className="aws-desc">Missing cluster name.</p>
  return <RunTaskForm cluster={decodeURIComponent(name)} />
}

export function EcsCreateServicePage() {
  const { name } = useParams<{ name?: string }>()
  if (!name) return <p className="aws-desc">Missing cluster name.</p>
  return <CreateServiceForm cluster={decodeURIComponent(name)} />
}
