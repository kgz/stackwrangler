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

function isMysqlEngine(engine: string | undefined): boolean {
  const name = (engine ?? '').toLowerCase()
  return name === 'mysql' || name === 'mariadb' || name.startsWith('aurora-mysql')
}

function connectHint(db: DBInstance): string {
  const host = db.Endpoint?.Address ?? '127.0.0.1'
  const user = db.MasterUsername ?? 'stackwrangler'
  const name = db.DBName ?? 'stackwrangler'
  const h =
    host.includes('rds.amazonaws.com') || host === 'localhost'
      ? '127.0.0.1'
      : host
  const mysql = isMysqlEngine(db.Engine)
  const port = db.Endpoint?.Port ?? (mysql ? 3306 : 5432)
  if (mysql) {
    return `mysql -h ${h} -P ${port} -u ${user} -p ${name}`
  }
  return `psql -h ${h} -p ${port} -U ${user} -d ${name}`
}

function engineLabel(db: DBInstance): string {
  const name = db.Engine ?? ''
  const pretty =
    name === 'postgres'
      ? 'PostgreSQL'
      : name === 'mysql'
        ? 'MySQL'
        : name === 'mariadb'
          ? 'MariaDB'
          : name
  return `${pretty || '—'} ${db.EngineVersion ?? ''}`.trim()
}

function InstancesList() {
  const [dbs, setDbs] = useState<DBInstance[]>([])
  const [filter, setFilter] = useState('')
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

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return dbs
    return dbs.filter((d) =>
      (d.DBInstanceIdentifier ?? '').toLowerCase().includes(q),
    )
  }, [dbs, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

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
    <ListCard
      title="Databases"
      desc={
        <>
          Amazon RDS makes it easier to set up, operate, and scale a relational
          database. Docker-backed instances when{' '}
          <code>RDS_DOCKER_BACKEND=1</code>; create via{' '}
          <code>./smokes/data/rds-smoke.sh</code> or <code>./smokes/data/rds-mysql-smoke.sh</code>.
        </>
      }
      notices={<Notices error={error} toast={toast} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <button
            type="button"
            className="btn btn-normal"
            disabled={!selected || busy}
            title={selected ? undefined : 'Select a row'}
            onClick={() => void onDelete()}
          >
            Delete
          </button>
          <DeadButton>Actions ▾</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create database</DeadButton>
        </>
      }
      placeholder="Filter databases"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="rds-databases-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>DB identifier</SortHeader>
            <FilterHeader>Status</FilterHeader>
            <FilterHeader>Role</FilterHeader>
            <FilterHeader>Engine</FilterHeader>
            <FilterHeader>Region & AZ</FilterHeader>
            <FilterHeader>Size</FilterHeader>
            <FilterHeader>VPC</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={8}
              loading={loading}
              loadingText="Loading databases…"
              title="No databases"
              text="Run ./smokes/data/rds-smoke.sh or ./smokes/data/rds-mysql-smoke.sh (keep with AWSBOX_RDS_KEEP=1 to inspect)."
            />
          ) : (
            filtered.map((db) => {
              const id = db.DBInstanceIdentifier ?? ''
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-db"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[id, db.DBInstanceArn]}>
                      <Link
                        to={`/rds/databases/${encodeURIComponent(id)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {id}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    <StatusBadge
                      status={db.DBInstanceStatus}
                      label={titleCase(db.DBInstanceStatus)}
                    />
                  </td>
                  <td>Instance</td>
                  <td>{engineLabel(db)}</td>
                  <td>{db.AvailabilityZone ?? '—'}</td>
                  <td>{db.DBInstanceClass ?? '—'}</td>
                  <td>
                    {db.DBSubnetGroup?.VpcId ? (
                      <Mono>{db.DBSubnetGroup.VpcId}</Mono>
                    ) : (
                      '—'
                    )}
                  </td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
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
      <DetailHeader
        title={
          <ResourceLabel ids={[id, db?.DBInstanceArn]} detail>
            {id}
          </ResourceLabel>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Actions ▾</DeadButton>
          </>
        }
        subtitle={
          db ? (
            <>
              <StatusBadge
                status={db.DBInstanceStatus}
                label={titleCase(db.DBInstanceStatus)}
              />
              <span>
                {engineLabel(db)} · {db.DBInstanceClass ?? '—'}
              </span>
            </>
          ) : null
        }
      />
      <Notices error={error} />
      {loading || !db ? (
        <p className="aws-desc">Loading…</p>
      ) : (
        <>
          <Section title="Connectivity & security">
            <Kv
              rows={[
                ['Endpoint', <Mono key="ep">{endpointLabel(db)}</Mono>],
                ['Port', db.Endpoint?.Port ?? '—'],
                ['Master username', db.MasterUsername ?? '—'],
                ['DB name', db.DBName ?? '—'],
                [
                  'VPC',
                  db.DBSubnetGroup?.VpcId ? (
                    <Mono key="vpc">{db.DBSubnetGroup.VpcId}</Mono>
                  ) : (
                    '—'
                  ),
                ],
                [
                  'Publicly accessible',
                  db.PubliclyAccessible === undefined
                    ? '—'
                    : db.PubliclyAccessible
                      ? 'Yes'
                      : 'No',
                ],
                ['Connect', <Mono key="cn">{connectHint(db)}</Mono>],
              ]}
            />
          </Section>
          <Section title="Configuration" spaced>
            <Kv
              rows={[
                ['DB instance class', db.DBInstanceClass ?? '—'],
                ['Engine version', db.EngineVersion ?? '—'],
                ['Storage type', db.StorageType ?? '—'],
                [
                  'Allocated storage',
                  db.AllocatedStorage === undefined
                    ? '—'
                    : `${db.AllocatedStorage} GiB`,
                ],
              ]}
            />
          </Section>
        </>
      )}
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
