import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
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
          Create via <code>./smokes/compute/ecs-smoke.sh</code> / terraform example.
        </>
      }
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Delete Cluster</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create Cluster</DeadButton>
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
        actions={<RefreshButton onClick={() => void refresh()} />}
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
                    <PlainHeader>Desired tasks</PlainHeader>
                    <PlainHeader>Running tasks</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {services.length === 0 ? (
                    <EmptyRow
                      colSpan={4}
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
                    <PlainHeader>Launch type</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {tasks.length === 0 ? (
                    <EmptyRow
                      colSpan={4}
                      loading={false}
                      loadingText=""
                      title="No tasks"
                    />
                  ) : (
                    tasks.map((t) => {
                      const arn = t.taskArn ?? ''
                      const short = arn.split('/').pop() ?? arn
                      return (
                        <tr key={arn}>
                          <td>
                            <ResourceLabel ids={[arn]}>
                              <Mono>{short || '—'}</Mono>
                            </ResourceLabel>
                          </td>
                          <td>
                            <StatusBadge status={t.lastStatus} />
                          </td>
                          <td>{t.desiredStatus ?? '—'}</td>
                          <td>{t.launchType ?? '—'}</td>
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

export function EcsClustersPage() {
  const { name } = useParams<{ name?: string }>()
  if (name) {
    return <ClusterDetail name={decodeURIComponent(name)} />
  }
  return <ClustersList />
}
