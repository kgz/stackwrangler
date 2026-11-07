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
  Section,
  SelectCell,
  SelectHeader,
  SortHeader,
  StatusBadge,
  titleCase,
} from '../components/ServiceUi'
import {
  describeInstance,
  formatLaunchTime,
  listInstances,
  nameTag,
  securityGroupLabel,
  type Instance,
} from '../lib/ec2'

function InstancesList() {
  const [instances, setInstances] = useState<Instance[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setInstances(await listInstances())
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
    if (!q) return instances
    return instances.filter((i) =>
      [
        nameTag(i.Tags),
        i.InstanceId,
        i.PrivateIpAddress,
        i.PublicDnsName,
        i.PublicIpAddress,
      ].some((v) => (v ?? '').toLowerCase().includes(q)),
    )
  }, [instances, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Instances"
      desc={
        <>
          Virtual servers in the cloud. Docker-backed via LocalEmu; create with{' '}
          <code>./smokes/compute/ec2-smoke.sh</code>. Launch wizard stays CLI
          for now.
        </>
      }
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Instance state ▾</DeadButton>
          <DeadButton>Actions ▾</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Launch instance</DeadButton>
        </>
      }
      placeholder="Search by name, ID, or IP"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="ec2-instances-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <SortHeader>Instance ID</SortHeader>
            <FilterHeader>Instance state</FilterHeader>
            <FilterHeader>Instance type</FilterHeader>
            <FilterHeader>Availability Zone</FilterHeader>
            <FilterHeader>Public IPv4 DNS</FilterHeader>
            <FilterHeader>Private IPv4</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={8}
              loading={loading}
              loadingText="Loading instances…"
              title="No instances"
            />
          ) : (
            filtered.map((i) => {
              const id = i.InstanceId ?? ''
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-instance"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>{nameTag(i.Tags)}</td>
                  <td>
                    <ResourceLabel ids={[i.InstanceId]}>
                      <Link
                        to={`/ec2/instances/${encodeURIComponent(id)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        <Mono>{id || '—'}</Mono>
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    <StatusBadge
                      status={i.State?.Name}
                      label={titleCase(i.State?.Name)}
                    />
                  </td>
                  <td>{i.InstanceType ?? '—'}</td>
                  <td>{i.Placement?.AvailabilityZone ?? '—'}</td>
                  <td>
                    {i.PublicDnsName ? <Mono>{i.PublicDnsName}</Mono> : '—'}
                  </td>
                  <td>{i.PrivateIpAddress ?? '—'}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}

function InstanceDetail({ instanceId }: { instanceId: string }) {
  const [instance, setInstance] = useState<Instance | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeInstance(instanceId)
      setInstance(found)
      if (!found) {
        setError(`Instance ${instanceId} not found`)
      }
    } catch (err) {
      setInstance(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [instanceId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const name = instance ? nameTag(instance.Tags) : '—'
  const iam =
    instance?.IamInstanceProfile?.Arn?.split('/').pop() ??
    instance?.IamInstanceProfile?.Id ??
    '—'

  return (
    <>
      <DetailHeader
        title={
          <ResourceLabel ids={[instanceId]} detail>
            <Mono>{instanceId}</Mono>
          </ResourceLabel>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Instance state ▾</DeadButton>
            <DeadButton>Actions ▾</DeadButton>
          </>
        }
        subtitle={
          instance ? (
            <>
              <StatusBadge
                status={instance.State?.Name}
                label={titleCase(instance.State?.Name)}
              />
              <span>
                {name !== '—' ? `${name} · ` : ''}
                {instance.InstanceType ?? '—'} ·{' '}
                {instance.Placement?.AvailabilityZone ?? '—'}
              </span>
            </>
          ) : null
        }
      />
      <Notices error={error} />
      {loading || !instance ? (
        <p className="aws-desc">Loading…</p>
      ) : (
        <>
          <Section title="Instance summary">
            <Kv
              rows={[
                [
                  'Instance ID',
                  <Mono key="id">{instance.InstanceId ?? '—'}</Mono>,
                ],
                ['Name', name],
                [
                  'Instance state',
                  <StatusBadge
                    key="st"
                    status={instance.State?.Name}
                    label={titleCase(instance.State?.Name)}
                  />,
                ],
                ['Instance type', instance.InstanceType ?? '—'],
                [
                  'Availability Zone',
                  instance.Placement?.AvailabilityZone ?? '—',
                ],
                ['Launch time', formatLaunchTime(instance.LaunchTime)],
                [
                  'AMI ID',
                  instance.ImageId ? (
                    <Mono key="ami">{instance.ImageId}</Mono>
                  ) : (
                    '—'
                  ),
                ],
                [
                  'Platform details',
                  instance.PlatformDetails ??
                    instance.Platform ??
                    'Linux/UNIX',
                ],
              ]}
            />
          </Section>
          <Section title="Networking" spaced>
            <Kv
              rows={[
                [
                  'Public IPv4 DNS',
                  instance.PublicDnsName ? (
                    <Mono key="pdns">{instance.PublicDnsName}</Mono>
                  ) : (
                    '—'
                  ),
                ],
                ['Public IPv4 address', instance.PublicIpAddress ?? '—'],
                [
                  'Private IPv4 DNS',
                  instance.PrivateDnsName ? (
                    <Mono key="privdns">{instance.PrivateDnsName}</Mono>
                  ) : (
                    '—'
                  ),
                ],
                ['Private IPv4 address', instance.PrivateIpAddress ?? '—'],
                [
                  'VPC ID',
                  instance.VpcId ? (
                    <Mono key="vpc">{instance.VpcId}</Mono>
                  ) : (
                    '—'
                  ),
                ],
                [
                  'Subnet ID',
                  instance.SubnetId ? (
                    <Mono key="sub">{instance.SubnetId}</Mono>
                  ) : (
                    '—'
                  ),
                ],
                [
                  'Security groups',
                  securityGroupLabel(instance.SecurityGroups),
                ],
                ['Key pair name', instance.KeyName ?? '—'],
                ['IAM role', iam],
              ]}
            />
          </Section>
        </>
      )}
      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to="/ec2">Back to instances</Link>
      </p>
    </>
  )
}

export function Ec2InstancesPage() {
  const { instanceId } = useParams<{ instanceId?: string }>()
  if (instanceId) {
    return (
      <InstanceDetail instanceId={decodeURIComponent(instanceId)} />
    )
  }
  return <InstancesList />
}
