import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import { importSshPublicKey, listUsers } from '../lib/transfer'

export function TransferImportSshKeyPage() {
  const { serverId: rawId } = useParams<{ serverId: string }>()
  const serverId = rawId ? decodeURIComponent(rawId) : ''
  const [searchParams] = useSearchParams()
  const navigate = useNavigate()
  const [users, setUsers] = useState<string[]>([])
  const [userName, setUserName] = useState(searchParams.get('user') ?? '')
  const [sshKey, setSshKey] = useState('')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const detailPath = `/transfer/servers/${encodeURIComponent(serverId)}`

  const refreshUsers = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const listed = await listUsers(serverId)
      const names = listed
        .map((u) => u.UserName)
        .filter((n): n is string => Boolean(n))
      setUsers(names)
      setUserName((cur) => {
        if (cur && names.includes(cur)) return cur
        return names[0] ?? ''
      })
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [serverId])

  useEffect(() => {
    void refreshUsers()
  }, [refreshUsers])

  async function onImport() {
    const name = userName.trim()
    const key = sshKey.trim()
    if (!name) {
      setError('User name is required')
      return
    }
    if (!key) {
      setError('SSH public key body is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await importSshPublicKey(serverId, name, key)
      navigate(`${detailPath}/users/${encodeURIComponent(name)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Import SSH public key</h1>
      <p className="aws-desc">
        Add an SSH public key to an existing service-managed user on{' '}
        <code className="aws-mono">{serverId}</code>. The user can then
        authenticate over SFTP with the matching private key.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">User</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="key-user">
                User name <span className="req">*</span>
              </label>
              <select
                className="aws-select"
                id="key-user"
                name="userName"
                style={{ maxWidth: 480, width: '100%' }}
                value={userName}
                onChange={(e) => setUserName(e.target.value)}
                disabled={loading || users.length === 0}
                data-testid="transfer-import-user"
              >
                {users.length === 0 ? (
                  <option value="">
                    {loading ? 'Loading users…' : 'No users on this server'}
                  </option>
                ) : (
                  users.map((n) => (
                    <option key={n} value={n}>
                      {n}
                    </option>
                  ))
                )}
              </select>
              <p className="aws-hint">
                Only service-managed users on this server are listed.
              </p>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">SSH public key</h2>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="keySource"
                    value="paste"
                    checked
                    onChange={() => undefined}
                    data-testid="transfer-key-source-paste"
                  />
                  <span>
                    <strong>Paste key body</strong>
                    <span className="sub">
                      Enter the SSH public key in OpenSSH format.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="keySource"
                    value="file"
                    disabled
                    aria-disabled="true"
                    title={TO_IMPLEMENT}
                  />
                  <span>
                    <strong>Upload a .pub file</strong>
                    <span className="sub">
                      Select a public key file from your computer.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label" htmlFor="ssh-key-body">
                Public key body <span className="req">*</span>
              </label>
              <textarea
                className="aws-input"
                id="ssh-key-body"
                name="sshPublicKeyBody"
                rows={5}
                placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI… user@host"
                spellCheck={false}
                style={{
                  height: 132,
                  padding: '8px 10px',
                  resize: 'vertical',
                  fontFamily: 'var(--font-mono)',
                  fontSize: 13,
                  lineHeight: 1.5,
                }}
                value={sshKey}
                onChange={(e) => setSshKey(e.target.value)}
                data-testid="transfer-import-ssh-key"
              />
              <p className="aws-hint">
                Paste a single public key including the algorithm prefix. A
                private key will not work. Each user can have up to 10 keys.
              </p>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to={detailPath}>
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy || !userName}
          onClick={() => void onImport()}
          data-testid="transfer-import-submit"
        >
          {busy ? 'Importing…' : 'Import key'}
        </button>
      </div>
    </>
  )
}
