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
  listLoadBalancers,
  type LoadBalancer,
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
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeLoadBalancer(arn)
      if (!found) throw new Error('Load balancer not found')
      setLb(found)
    } catch (err) {
      setLb(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [arn])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const name = lb?.LoadBalancerName ?? arn

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
      {loading || !lb ? (
        <p className="aws-desc">Loading…</p>
      ) : (
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
      )}
      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to="/ec2/load-balancers">Back to load balancers</Link>
      </p>
    </>
  )
}

export function LoadBalancersPage() {
  const [params] = useSearchParams()
  const arn = params.get('arn')
  if (arn) return <LoadBalancerDetail arn={arn} />
  return <LoadBalancerList />
}
