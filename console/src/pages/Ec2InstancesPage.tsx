import { useCallback, useEffect, useMemo, useState } from 'react'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  ListCard,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
  StatusBadge,
  titleCase,
} from '../components/ServiceUi'
import { listInstances, nameTag, type Instance } from '../lib/ec2'

export function Ec2InstancesPage() {
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
          <code>./smokes/compute/ec2-smoke.sh</code>.
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
                      <Mono>{id || '—'}</Mono>
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
