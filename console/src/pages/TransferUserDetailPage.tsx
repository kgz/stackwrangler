import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { RefreshButton, TO_IMPLEMENT } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  Kv,
  Mono,
  Notices,
  PlainHeader,
  Section,
  StatusBadge,
} from '../components/ServiceUi'
import { describeUser, type DescribedUser } from '../lib/transfer'
import { formatServiceDate } from '../lib/format'

export function TransferUserDetailPage() {
  const { serverId: rawServer, userName: rawUser } = useParams<{
    serverId: string
    userName: string
  }>()
  const serverId = rawServer ? decodeURIComponent(rawServer) : ''
  const userName = rawUser ? decodeURIComponent(rawUser) : ''
  const [user, setUser] = useState<DescribedUser | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const serverPath = `/transfer/servers/${encodeURIComponent(serverId)}`
  const importPath = `${serverPath}/users/import-ssh-key?user=${encodeURIComponent(userName)}`

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setUser(await describeUser(serverId, userName))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [serverId, userName])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const keys = user?.SshPublicKeys ?? []

  return (
    <>
      <DetailHeader
        title={
          <ResourceLabel ids={[userName, user?.Arn]} detail>
            {userName}
          </ResourceLabel>
        }
        actions={
          <>
            <button
              type="button"
              className="btn btn-normal"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
            >
              Delete user
            </button>
            <RefreshButton onClick={() => void refresh()} />
          </>
        }
        subtitle={
          <>
            <StatusBadge status="ONLINE" label="Active" />
            <span>
              {serverId} · SFTP · Service managed
            </span>
          </>
        }
      />
      <Notices error={error} />
      {loading ? (
        <p className="aws-desc">Loading…</p>
      ) : (
        <>
          <Section title="User overview">
            <Kv
              rows={[
                [
                  'Server ID',
                  <Link key="sid" to={serverPath}>
                    {serverId}
                  </Link>,
                ],
                ['Identity provider', 'Service managed'],
                [
                  'Role ARN',
                  <Mono key="role">{user?.Role ?? '—'}</Mono>,
                ],
                [
                  'Home directory type',
                  user?.HomeDirectoryType ?? 'PATH',
                ],
                [
                  'Home directory',
                  <Mono key="home">{user?.HomeDirectory ?? '—'}</Mono>,
                ],
                ['ARN', <Mono key="arn">{user?.Arn ?? '—'}</Mono>],
              ]}
            />
          </Section>
          <Section
            title={`SSH public keys (${keys.length} of 10)`}
            spaced
          >
            <div className="aws-toolbar" style={{ marginBottom: 12 }}>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Remove key
              </button>
              <div className="spacer" />
              <Link
                className="btn btn-primary"
                to={importPath}
                data-testid="transfer-user-add-key"
              >
                Add SSH key
              </Link>
            </div>
            <div className="aws-table-wrap">
              <table
                className="aws-table"
                data-testid="transfer-ssh-keys-table"
              >
                <thead>
                  <tr>
                    <PlainHeader>Key ID</PlainHeader>
                    <PlainHeader>Public key body</PlainHeader>
                    <PlainHeader>Date added</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {keys.length === 0 ? (
                    <EmptyRow
                      colSpan={3}
                      loading={false}
                      loadingText=""
                      title="No SSH public keys"
                      text="Import a key to authenticate over SFTP."
                    />
                  ) : (
                    keys.map((k) => (
                      <tr key={k.SshPublicKeyId ?? k.SshPublicKeyBody}>
                        <td>
                          <Mono>{k.SshPublicKeyId ?? '—'}</Mono>
                        </td>
                        <td>
                          <Mono>{k.SshPublicKeyBody ?? '—'}</Mono>
                        </td>
                        <td>
                          {k.DateImported
                            ? formatServiceDate(k.DateImported)
                            : '—'}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </Section>
        </>
      )}
      <p className="aws-desc" style={{ marginTop: 16 }}>
        <Link to={serverPath}>Back to server</Link>
      </p>
    </>
  )
}
