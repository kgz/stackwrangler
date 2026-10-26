import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import {
  createSftpServer,
  deleteServer,
  describeServer,
  listServers,
  listUsers,
  type DescribedServer,
  type ListedServer,
  type ListedUser,
} from '../lib/transfer'

function ServersList() {
  const navigate = useNavigate()
  const [servers, setServers] = useState<ListedServer[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setServers(await listServers())
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

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
    <>
      <div className="crumbs">
        <span>AWS Transfer Family</span>
        <span className="crumbs-sep">/</span>
        <span>Servers</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          Servers ({loading ? '…' : servers.length})
        </h1>
        <div className="cfn-page-actions">
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn"
            disabled={!selected || busy}
            onClick={() => void onDelete()}
          >
            Delete
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={busy}
            onClick={() => void onCreate()}
          >
            Create server
          </button>
        </div>
      </div>

      <p className="page-lead">
        Native Transfer SFTP (SSH public keys) on <code>127.0.0.1:2222</code>.
        Create users / import keys via CLI until the console form lands — see{' '}
        <code>docs/transfer.md</code>.
      </p>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}

      <div className="panel">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : servers.length === 0 ? (
          <div className="empty">
            <strong>No servers</strong>
            Create one here or run <code>./bin/transfer-smoke.sh</code>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th className="col-check" aria-label="Select" />
                <th>Server ID</th>
                <th>State</th>
                <th>Identity</th>
                <th>Users</th>
              </tr>
            </thead>
            <tbody>
              {servers.map((s) => {
                const id = s.ServerId ?? ''
                return (
                  <tr
                    key={id}
                    className={selected === id ? 'row-selected' : undefined}
                    onClick={() => setSelected(id)}
                  >
                    <td className="col-check">
                      <input
                        type="radio"
                        name="xfer"
                        checked={selected === id}
                        aria-label={`Select ${id}`}
                        onChange={() => setSelected(id)}
                      />
                    </td>
                    <td>
                      <ResourceLabel ids={[id, s.Arn]}>
                        <button
                          type="button"
                          className="btn-link"
                          onClick={(e) => {
                            e.stopPropagation()
                            navigate(
                              `/transfer/servers/${encodeURIComponent(id)}`,
                            )
                          }}
                        >
                          {id}
                        </button>
                      </ResourceLabel>
                    </td>
                    <td>{s.State ?? '—'}</td>
                    <td className="cfn-muted">
                      {s.IdentityProviderType ?? '—'}
                    </td>
                    <td>{s.UserCount ?? '—'}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
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

  return (
    <>
      <div className="crumbs">
        <Link to="/transfer">AWS Transfer Family</Link>
        <span className="crumbs-sep">/</span>
        <Link to="/transfer">Servers</Link>
        <span className="crumbs-sep">/</span>
        <span>{serverId}</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          <ResourceLabel ids={[serverId, server?.Arn]} detail>
            {serverId}
          </ResourceLabel>
        </h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel cfn-overview">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : (
          <>
            <section>
              <h2 className="cfn-section-title">Overview</h2>
              <dl className="cfn-kv">
                <div>
                  <dt>State</dt>
                  <dd>{server?.State ?? '—'}</dd>
                </div>
                <div>
                  <dt>Protocols</dt>
                  <dd>{(server?.Protocols ?? []).join(', ') || '—'}</dd>
                </div>
                <div>
                  <dt>Identity provider</dt>
                  <dd>{server?.IdentityProviderType ?? '—'}</dd>
                </div>
                <div>
                  <dt>User count</dt>
                  <dd>{server?.UserCount ?? '—'}</dd>
                </div>
              </dl>
            </section>
            <section>
              <h2 className="cfn-section-title">Users</h2>
              {users.length === 0 ? (
                <p className="cfn-muted">
                  No users listed (LocalEmu list-users may be empty). Create user
                  + <code>import-ssh-public-key</code> via CLI (
                  <code>./bin/transfer-key-smoke.sh</code>).
                </p>
              ) : (
                <table className="data">
                  <thead>
                    <tr>
                      <th>User name</th>
                      <th>Home</th>
                      <th>Role</th>
                    </tr>
                  </thead>
                  <tbody>
                    {users.map((u) => (
                      <tr key={u.UserName}>
                        <td>{u.UserName ?? '—'}</td>
                        <td className="cfn-muted">{u.HomeDirectory ?? '—'}</td>
                        <td className="cfn-muted">
                          <ResourceLabel ids={[u.Arn]}>
                            <code>{u.Arn ?? '—'}</code>
                          </ResourceLabel>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </section>
            <section>
              <h2 className="cfn-section-title">Data plane</h2>
              <p className="cfn-muted">
                SFTP listen: <code>sftp -i key -P 2222 user@127.0.0.1</code>{' '}
                (native LocalEmu; SSH keys). Smoke:{' '}
                <code>./bin/transfer-key-smoke.sh</code>
              </p>
            </section>
          </>
        )}
      </div>
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
