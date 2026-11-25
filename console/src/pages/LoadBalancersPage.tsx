import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
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
  Section,
  SelectCell,
  SelectHeader,
  SortHeader,
  StatusBadge,
  titleCase,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  describeLoadBalancer,
  describeTargetHealthForGroups,
  listListeners,
  listLoadBalancers,
  listTargetGroups,
  type Listener,
  type LoadBalancer,
  type TargetGroup,
  type TargetHealthDescription,
} from '../lib/elbv2'

function lbPath(arn: string): string {
  return `/ec2/load-balancers?arn=${encodeURIComponent(arn)}`
}

function azList(lb: LoadBalancer): string {
  return (
    (lb.AvailabilityZones ?? [])
      .map((z) => z.ZoneName)
      .filter(Boolean)
      .join(', ') || '—'
  )
}

function tgNameFromArn(arn: string | undefined, byArn: Map<string, TargetGroup>): string {
  if (!arn) return '—'
  const tg = byArn.get(arn)
  if (tg?.TargetGroupName) return tg.TargetGroupName
  const parts = arn.split('/')
  return parts[parts.length - 1] || arn
}

function defaultActionLabel(
  listener: Listener,
  byArn: Map<string, TargetGroup>,
): string {
  const action = listener.DefaultActions?.[0]
  if (!action) return '—'
  if (action.Type === 'forward') {
    const name = tgNameFromArn(action.TargetGroupArn, byArn)
    return `Forward to ${name}`
  }
  return action.Type ?? '—'
}

type HealthRow = {
  key: string
  targetGroupName: string
  targetId: string
  port: string
  state: string | undefined
  reason: string
}

function healthRowsFrom(
  groups: TargetGroup[],
  healthByTg: Map<string, TargetHealthDescription[]>,
): HealthRow[] {
  const rows: HealthRow[] = []
  for (const tg of groups) {
    const arn = tg.TargetGroupArn ?? ''
    const name = tg.TargetGroupName ?? arn
    const descs = healthByTg.get(arn) ?? []
    if (descs.length === 0) {
      rows.push({
        key: `${arn}:empty`,
        targetGroupName: name,
        targetId: '—',
        port: '—',
        state: undefined,
        reason: 'No registered targets',
      })
      continue
    }
    for (const desc of descs) {
      const id = desc.Target?.Id ?? '—'
      const port = desc.Target?.Port
      rows.push({
        key: `${arn}:${id}:${port ?? ''}`,
        targetGroupName: name,
        targetId: id,
        port: port != null ? String(port) : '—',
        state: desc.TargetHealth?.State,
        reason:
          desc.TargetHealth?.Description ||
          desc.TargetHealth?.Reason ||
          '—',
      })
    }
  }
  return rows
}

function LoadBalancerList() {
  const [lbs, setLbs] = useState<LoadBalancer[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setLbs(await listLoadBalancers())
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
    if (!q) return lbs
    return lbs.filter(
      (lb) =>
        (lb.LoadBalancerName ?? '').toLowerCase().includes(q) ||
        (lb.DNSName ?? '').toLowerCase().includes(q),
    )
  }, [lbs, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Load balancers"
      desc={
        <>
          Distribute incoming traffic across multiple targets in one or more
          Availability Zones. Display names come from{' '}
          <code>STACKWRANGLER_LABELS</code> (<code>docs/labels.md</code>).
        </>
      }
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Actions ▾</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create load balancer</DeadButton>
        </>
      }
      placeholder="Search load balancers"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="ec2-lbs-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>DNS name</FilterHeader>
            <FilterHeader>State</FilterHeader>
            <FilterHeader>VPC ID</FilterHeader>
            <FilterHeader>Availability Zones</FilterHeader>
            <FilterHeader>Type</FilterHeader>
            <SortHeader>Date created</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={8}
              loading={loading}
              loadingText="Loading load balancers…"
              title="No load balancers"
            />
          ) : (
            filtered.map((lb) => {
              const arn = lb.LoadBalancerArn ?? ''
              const name = lb.LoadBalancerName ?? arn
              const key = arn || name
              const isSelected = selected === key
              return (
                <tr
                  key={key}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(key)}
                >
                  <SelectCell
                    name="selected-lb"
                    id={name}
                    selected={isSelected}
                    onToggle={() => toggle(key)}
                  />
                  <td>
                    <ResourceLabel ids={[arn, name]}>
                      <Link
                        to={arn ? lbPath(arn) : '/ec2/load-balancers'}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {name || '—'}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    {lb.DNSName ? <Mono>{lb.DNSName}</Mono> : '—'}
                  </td>
                  <td>
                    <StatusBadge
                      status={lb.State?.Code}
                      label={titleCase(lb.State?.Code)}
                    />
                  </td>
                  <td>{lb.VpcId ? <Mono>{lb.VpcId}</Mono> : '—'}</td>
                  <td>{azList(lb)}</td>
                  <td>{lb.Type ?? '—'}</td>
                  <td>{formatServiceDate(lb.CreatedTime)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}

function LoadBalancerDetail({ arn }: { arn: string }) {
  const [lb, setLb] = useState<LoadBalancer | null>(null)
  const [listeners, setListeners] = useState<Listener[]>([])
  const [targetGroups, setTargetGroups] = useState<TargetGroup[]>([])
  const [healthByTg, setHealthByTg] = useState<
    Map<string, TargetHealthDescription[]>
  >(new Map())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeLoadBalancer(arn)
      if (!found) throw new Error('Load balancer not found')
      const [lis, tgs] = await Promise.all([
        listListeners(arn),
        listTargetGroups(arn),
      ])
      const healthRows = await describeTargetHealthForGroups(tgs)
      const healthMap = new Map<string, TargetHealthDescription[]>()
      for (const row of healthRows) {
        healthMap.set(row.targetGroupArn, row.health)
      }
      setLb(found)
      setListeners(lis)
      setTargetGroups(tgs)
      setHealthByTg(healthMap)
    } catch (err) {
      setLb(null)
      setListeners([])
      setTargetGroups([])
      setHealthByTg(new Map())
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [arn])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const name = lb?.LoadBalancerName ?? arn
  const tgByArn = useMemo(() => {
    const map = new Map<string, TargetGroup>()
    for (const tg of targetGroups) {
      if (tg.TargetGroupArn) map.set(tg.TargetGroupArn, tg)
    }
    return map
  }, [targetGroups])
  const healthRows = useMemo(
    () => healthRowsFrom(targetGroups, healthByTg),
    [targetGroups, healthByTg],
  )

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
        subtitle={
          lb ? (
            <>
              <StatusBadge
                status={lb.State?.Code}
                label={titleCase(lb.State?.Code)}
              />
              <span>{lb.Type ?? '—'}</span>
            </>
          ) : null
        }
      />
      <Notices error={error} />
      <p className="aws-desc" style={{ marginBottom: 16 }}>
        <Link to="/ec2/load-balancers">← Back to load balancers</Link>
      </p>
      {loading || !lb ? (
        <p className="aws-desc">Loading…</p>
      ) : (
        <>
          <Section title="Overview">
            <Kv
              rows={[
                [
                  'ARN',
                  <ResourceLabel key="arn" ids={[lb.LoadBalancerArn]} detail>
                    <Mono>{lb.LoadBalancerArn ?? '—'}</Mono>
                  </ResourceLabel>,
                ],
                ['DNS name', lb.DNSName ?? '—'],
                [
                  'State',
                  <StatusBadge
                    key="st"
                    status={lb.State?.Code}
                    label={titleCase(lb.State?.Code)}
                  />,
                ],
                ['Type', lb.Type ?? '—'],
                ['Scheme', lb.Scheme ?? '—'],
                ['VPC ID', lb.VpcId ? <Mono key="vpc">{lb.VpcId}</Mono> : '—'],
                ['Availability Zones', azList(lb)],
              ]}
            />
          </Section>

          <Section title="Listeners" spaced>
            <div className="aws-toolbar" style={{ marginBottom: 12 }}>
              <div className="spacer" />
              <DeadButton variant="primary">Create listener</DeadButton>
            </div>
            <table className="aws-table" data-testid="ec2-lb-listeners-table">
              <thead>
                <tr>
                  <th>Protocol</th>
                  <th>Port</th>
                  <th>Default action</th>
                  <th>Listener ARN</th>
                </tr>
              </thead>
              <tbody>
                {listeners.length === 0 ? (
                  <EmptyRow
                    colSpan={4}
                    loading={false}
                    loadingText=""
                    title="No listeners"
                  />
                ) : (
                  listeners.map((lis) => {
                    const lisArn = lis.ListenerArn ?? ''
                    return (
                      <tr key={lisArn || `${lis.Protocol}:${lis.Port}`}>
                        <td>{lis.Protocol ?? '—'}</td>
                        <td>{lis.Port ?? '—'}</td>
                        <td>{defaultActionLabel(lis, tgByArn)}</td>
                        <td>
                          {lisArn ? <Mono>{lisArn}</Mono> : '—'}
                        </td>
                      </tr>
                    )
                  })
                )}
              </tbody>
            </table>
          </Section>

          <Section title="Target health" spaced>
            <table
              className="aws-table"
              data-testid="ec2-lb-target-health-table"
            >
              <thead>
                <tr>
                  <th>Target group</th>
                  <th>Target</th>
                  <th>Port</th>
                  <th>Health state</th>
                  <th>Reason</th>
                </tr>
              </thead>
              <tbody>
                {healthRows.length === 0 ? (
                  <EmptyRow
                    colSpan={5}
                    loading={false}
                    loadingText=""
                    title="No target groups"
                  />
                ) : (
                  healthRows.map((row) => (
                    <tr key={row.key}>
                      <td>
                        <Mono>{row.targetGroupName}</Mono>
                      </td>
                      <td>
                        {row.targetId === '—' ? (
                          '—'
                        ) : (
                          <Mono>{row.targetId}</Mono>
                        )}
                      </td>
                      <td>{row.port}</td>
                      <td>
                        {row.state ? (
                          <StatusBadge
                            status={row.state}
                            label={titleCase(row.state)}
                          />
                        ) : (
                          '—'
                        )}
                      </td>
                      <td>{row.reason}</td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </Section>
        </>
      )}
    </>
  )
}

export function LoadBalancersPage() {
  const [params] = useSearchParams()
  const arn = params.get('arn')
  if (arn) return <LoadBalancerDetail arn={arn} />
  return <LoadBalancerList />
}
