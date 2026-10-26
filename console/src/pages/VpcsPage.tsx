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
  SelectCell,
  SelectHeader,
  SortHeader,
  StatusBadge,
  TabBar,
  titleCase,
} from '../components/ServiceUi'
import {
  describeVpc,
  listSubnets,
  listVpcs,
  nameTag,
  type Subnet,
  type Vpc,
} from '../lib/ec2'

function ipv6Cidr(vpc: Vpc): string {
  return vpc.Ipv6CidrBlockAssociationSet?.[0]?.Ipv6CidrBlock ?? '—'
}

function VpcList() {
  const [vpcs, setVpcs] = useState<Vpc[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setVpcs(await listVpcs())
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
    if (!q) return vpcs
    return vpcs.filter(
      (v) =>
        (v.VpcId ?? '').toLowerCase().includes(q) ||
        nameTag(v.Tags).toLowerCase().includes(q) ||
        (v.CidrBlock ?? '').includes(q),
    )
  }, [vpcs, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Your VPCs"
      desc={
        <>
          A virtual private cloud (VPC) is a virtual network dedicated to your
          account. Display names come from <code>AWSBOX_LABELS</code> (
          <code>docs/labels.md</code>).
        </>
      }
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Actions ▾</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create VPC</DeadButton>
        </>
      }
      placeholder="Search VPCs"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="ec2-vpcs-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <SortHeader>VPC ID</SortHeader>
            <FilterHeader>State</FilterHeader>
            <FilterHeader>IPv4 CIDR</FilterHeader>
            <FilterHeader>IPv6 CIDR</FilterHeader>
            <FilterHeader>DHCP option set</FilterHeader>
            <FilterHeader>Default VPC</FilterHeader>
            <FilterHeader>Owner ID</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={9}
              loading={loading}
              loadingText="Loading VPCs…"
              title="No VPCs"
            />
          ) : (
            filtered.map((vpc) => {
              const id = vpc.VpcId ?? ''
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-vpc"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>{nameTag(vpc.Tags)}</td>
                  <td>
                    <ResourceLabel ids={[id]}>
                      <Link
                        to={`/ec2/vpcs/${encodeURIComponent(id)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {id || '—'}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    <StatusBadge
                      status={vpc.State}
                      label={titleCase(vpc.State)}
                    />
                  </td>
                  <td>{vpc.CidrBlock ?? '—'}</td>
                  <td>{ipv6Cidr(vpc)}</td>
                  <td>
                    {vpc.DhcpOptionsId ? <Mono>{vpc.DhcpOptionsId}</Mono> : '—'}
                  </td>
                  <td>{vpc.IsDefault ? 'Yes' : 'No'}</td>
                  <td>{vpc.OwnerId ?? '—'}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}

const VPC_TABS = [
  ['details', 'Details'],
  ['cidrs', 'CIDR blocks'],
  ['subnets', 'Subnets'],
  ['tags', 'Tags'],
] as const

type VpcTab = (typeof VPC_TABS)[number][0]

function VpcDetail({ vpcId }: { vpcId: string }) {
  const [tab, setTab] = useState<VpcTab>('details')
  const [vpc, setVpc] = useState<Vpc | null>(null)
  const [subnets, setSubnets] = useState<Subnet[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeVpc(vpcId)
      if (!found) throw new Error(`VPC ${vpcId} not found`)
      setVpc(found)
      setSubnets(await listSubnets(vpcId).catch(() => []))
    } catch (err) {
      setVpc(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [vpcId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const cidrs = vpc?.CidrBlockAssociationSet ?? []
  const tags = vpc?.Tags ?? []

  return (
    <>
      <DetailHeader
        title={vpcId}
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Actions ▾</DeadButton>
          </>
        }
        subtitle={
          vpc ? (
            <>
              <StatusBadge status={vpc.State} label={titleCase(vpc.State)} />
              <span>{nameTag(vpc.Tags)}</span>
            </>
          ) : null
        }
      />
      <Notices error={error} />
      <section className="aws-card">
        <TabBar<VpcTab> tabs={VPC_TABS} active={tab} onChange={setTab} />
        <div className="aws-card-body">
          {loading || !vpc ? (
            <p className="aws-desc">Loading…</p>
          ) : tab === 'details' ? (
            <>
              <h2 className="aws-section-title">Details</h2>
              <Kv
                rows={[
                  [
                    'VPC ID',
                    <ResourceLabel key="id" ids={[vpc.VpcId]} detail>
                      <Mono>{vpc.VpcId ?? '—'}</Mono>
                    </ResourceLabel>,
                  ],
                  [
                    'State',
                    <StatusBadge
                      key="st"
                      status={vpc.State}
                      label={titleCase(vpc.State)}
                    />,
                  ],
                  ['IPv4 CIDR', vpc.CidrBlock ?? '—'],
                  ['IPv6 CIDR', ipv6Cidr(vpc)],
                  [
                    'DHCP option set',
                    vpc.DhcpOptionsId ? <Mono key="dh">{vpc.DhcpOptionsId}</Mono> : '—',
                  ],
                  ['Tenancy', titleCase(vpc.InstanceTenancy)],
                  ['Default VPC', vpc.IsDefault ? 'Yes' : 'No'],
                  ['Owner ID', vpc.OwnerId ?? '—'],
                ]}
              />
            </>
          ) : tab === 'cidrs' ? (
            <div className="aws-table-wrap">
              <table className="aws-table" data-testid="vpc-cidrs-table">
                <thead>
                  <tr>
                    <PlainHeader>CIDR</PlainHeader>
                    <PlainHeader>State</PlainHeader>
                    <PlainHeader>Association ID</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {cidrs.length === 0 ? (
                    <EmptyRow
                      colSpan={3}
                      loading={false}
                      loadingText=""
                      title="No CIDR blocks"
                    />
                  ) : (
                    cidrs.map((c) => (
                      <tr key={c.AssociationId ?? c.CidrBlock}>
                        <td>{c.CidrBlock ?? '—'}</td>
                        <td>
                          <StatusBadge
                            status={c.CidrBlockState?.State}
                            label={titleCase(c.CidrBlockState?.State)}
                          />
                        </td>
                        <td>
                          <Mono>{c.AssociationId ?? '—'}</Mono>
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          ) : tab === 'subnets' ? (
            <div className="aws-table-wrap">
              <table className="aws-table" data-testid="vpc-subnets-table">
                <thead>
                  <tr>
                    <PlainHeader>Name</PlainHeader>
                    <PlainHeader>Subnet ID</PlainHeader>
                    <PlainHeader>CIDR</PlainHeader>
                    <PlainHeader>AZ</PlainHeader>
                    <PlainHeader>State</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {subnets.length === 0 ? (
                    <EmptyRow
                      colSpan={5}
                      loading={false}
                      loadingText=""
                      title="No subnets"
                    />
                  ) : (
                    subnets.map((s) => (
                      <tr key={s.SubnetId}>
                        <td>{nameTag(s.Tags)}</td>
                        <td>
                          <Mono>{s.SubnetId ?? '—'}</Mono>
                        </td>
                        <td>{s.CidrBlock ?? '—'}</td>
                        <td>{s.AvailabilityZone ?? '—'}</td>
                        <td>
                          <StatusBadge
                            status={s.State}
                            label={titleCase(s.State)}
                          />
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          ) : tags.length === 0 ? (
            <p className="aws-desc">No tags</p>
          ) : (
            <div className="aws-table-wrap">
              <table className="aws-table">
                <thead>
                  <tr>
                    <PlainHeader>Key</PlainHeader>
                    <PlainHeader>Value</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {tags.map((t) => (
                    <tr key={t.Key}>
                      <td>{t.Key}</td>
                      <td>{t.Value}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>
    </>
  )
}

export function VpcsPage() {
  const { vpcId } = useParams()
  if (vpcId) return <VpcDetail vpcId={decodeURIComponent(vpcId)} />
  return <VpcList />
}
