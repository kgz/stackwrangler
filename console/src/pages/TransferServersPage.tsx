import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { RefreshButton } from '../components/S3Ui'
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
  titleCase,
} from '../components/ServiceUi'
import {
  createSftpServer,
  deleteServer,
  describeServer,
  listServersDetailed,
  listUsers,
  type DescribedServer,
  type ListedServer,
  type ListedUser,
} from '../lib/transfer'

type ServerRow = ListedServer & { Protocols?: string[] }

const SFTP_PORT = 2222
const SFTP_HOST = '127.0.0.1'

function endpointTypeLabel(t: string | undefined): string {
  return titleCase(t)
}

function identityLabel(t: string | undefined): string {
  if (t === 'SERVICE_MANAGED') return 'Service managed'
  return t ? titleCase(t.replace(/_/g, ' ')) : '—'
}

function ServersList() {
  const [servers, setServers] = useState<ServerRow[]>([])
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
      setServers(await listServersDetailed())
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
    if (!q) return servers
    return servers.filter((s) => (s.ServerId ?? '').toLowerCase().includes(q))
  }, [servers, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onCreate() {
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      const id = await createSftpServer()
      setToast(`Created server ${id}`)
      setSelected(id)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onDelete() {
    if (!selected) return
    setBusy(true)
    setError(null)
    try {
      await deleteServer(selected)
      setToast(`Deleted ${selected}`)
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
      title="Servers"
      desc={
        <>
          Transfer Family provides fully managed support for transferring files
          over SFTP, FTPS, and FTP. Control plane via LocalEmu; SFTP bytes use
          the awsbox sidecar on <code>{SFTP_HOST}:{SFTP_PORT}</code> — see{' '}
          <code>docs/transfer.md</code>.
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
          <div className="spacer" />
          <button
            type="button"
            className="btn btn-primary"
            disabled={busy}
            onClick={() => void onCreate()}
          >
            Create server
          </button>
        </>
      }
      placeholder="Search servers"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="transfer-servers-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Server ID</SortHeader>
            <FilterHeader>Protocol</FilterHeader>
            <FilterHeader>Endpoint type</FilterHeader>
            <FilterHeader>Identity provider</FilterHeader>
            <FilterHeader>State</FilterHeader>
            <SortHeader>Users</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={7}
              loading={loading}
              loadingText="Loading servers…"
              title="No servers"
              text="Create one here or run ./bin/transfer-smoke.sh"
            />
          ) : (
            filtered.map((s) => {
              const id = s.ServerId ?? ''
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-server"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[id, s.Arn]}>
                      <Link
                        to={`/transfer/servers/${encodeURIComponent(id)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {id}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>{s.Protocols?.join(', ') || '—'}</td>
                  <td>{endpointTypeLabel(s.EndpointType)}</td>
                  <td>{identityLabel(s.IdentityProviderType)}</td>
                  <td>
                    <StatusBadge
                      status={s.State}
                      label={titleCase(s.State)}
                    />
                  </td>
                  <td>{s.UserCount ?? '—'}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}

function ServerDetail({ serverId }: { serverId: string }) {
  const [server, setServer] = useState<DescribedServer | null>(null)
  const [users, setUsers] = useState<ListedUser[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [s, u] = await Promise.all([
        describeServer(serverId),
        listUsers(serverId).catch(() => []),
      ])
      setServer(s)
      setUsers(u)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [serverId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const protocols = (server?.Protocols ?? []).join(', ') || '—'
  const endpointType = endpointTypeLabel(server?.EndpointType)

  return (
    <>
      <DetailHeader
        title={
          <ResourceLabel ids={[serverId, server?.Arn]} detail>
            {serverId}
          </ResourceLabel>
        }
        actions={<RefreshButton onClick={() => void refresh()} />}
        subtitle={
          server ? (
            <>
              <StatusBadge
                status={server.State}
                label={titleCase(server.State)}
              />
              <span>
                {protocols} · {endpointType} endpoint
              </span>
            </>
          ) : null
        }
      />
      <Notices error={error} />
      {loading ? (
        <p className="aws-desc">Loading…</p>
      ) : (
        <>
          <Section title="Overview">
            <Kv
              rows={[
                [
                  'State',
                  <StatusBadge
                    key="state"
                    status={server?.State}
                    label={titleCase(server?.State)}
                  />,
                ],
                ['Protocols', protocols],
                [
                  'Identity provider',
                  identityLabel(server?.IdentityProviderType),
                ],
                ['Endpoint type', endpointType],
                ['User count', server?.UserCount ?? '—'],
                ['ARN', <Mono key="arn">{server?.Arn ?? '—'}</Mono>],
              ]}
            />
          </Section>
          <Section title="Users" spaced>
            <div className="aws-table-wrap">
              <table className="aws-table" data-testid="transfer-users-table">
                <thead>
                  <tr>
                    <PlainHeader>User name</PlainHeader>
                    <PlainHeader>Home directory</PlainHeader>
                    <PlainHeader>Role</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {users.length === 0 ? (
                    <EmptyRow
                      colSpan={3}
                      loading={false}
                      loadingText=""
                      title="No users"
                      text="LocalEmu list-users may be empty. Create via CLI smoke."
                    />
                  ) : (
                    users.map((u) => (
                      <tr key={u.UserName}>
                        <td>{u.UserName ?? '—'}</td>
                        <td>
                          <Mono>{u.HomeDirectory ?? '—'}</Mono>
                        </td>
                        <td>
                          <ResourceLabel ids={[u.Arn]}>
                            <Mono>{u.Arn ?? '—'}</Mono>
                          </ResourceLabel>
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </Section>
          <Section title="Data plane" spaced>
            <Kv
              rows={[
                ['Endpoint', <Mono key="ep">{SFTP_HOST}</Mono>],
                ['Port', SFTP_PORT],
                ['Protocol', 'SFTP'],
                ['Host key fingerprint', '—'],
                [
                  'Connect',
                  <Mono key="cn">{`sftp -P ${SFTP_PORT} awsbox@${SFTP_HOST}`}</Mono>,
                ],
              ]}
            />
            <p className="aws-desc" style={{ marginTop: 12 }}>
              Compose <code>sftp</code> service. Bridge smoke:{' '}
              <code>./bin/transfer-dataplane-smoke.sh</code>
            </p>
          </Section>
        </>
      )}
      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to="/transfer">Back to servers</Link>
      </p>
    </>
  )
}

export function TransferServersPage() {
  const { serverId } = useParams<{ serverId?: string }>()
  if (serverId) {
    return <ServerDetail serverId={decodeURIComponent(serverId)} />
  }
  return <ServersList />
}
