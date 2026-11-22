import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import { createUser } from '../lib/transfer'

export function TransferCreateUserPage() {
  const { serverId: rawId } = useParams<{ serverId: string }>()
  const serverId = rawId ? decodeURIComponent(rawId) : ''
  const navigate = useNavigate()
  const [userName, setUserName] = useState('')
  const [roleArn, setRoleArn] = useState('')
  const [homeDirectory, setHomeDirectory] = useState('')
  const [sshKey, setSshKey] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const detailPath = `/transfer/servers/${encodeURIComponent(serverId)}`

  async function onCreate() {
    const name = userName.trim()
    const role = roleArn.trim()
    if (!name) {
      setError('User name is required')
      return
    }
    if (!role) {
      setError('Role ARN is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createUser({
        serverId,
        userName: name,
        roleArn: role,
        homeDirectory,
        sshPublicKeyBody: sshKey,
      })
      navigate(
        `${detailPath}/users/${encodeURIComponent(name)}`,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create user</h1>
      <p className="aws-desc">
        Add a service-managed user to <code className="aws-mono">{serverId}</code>.
        Users authenticate with an SSH public key and are mapped to an IAM role
        and home directory.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">User configuration</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="user-name">
                User name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="user-name"
                name="userName"
                type="text"
                autoComplete="off"
                placeholder="my-user"
                value={userName}
                onChange={(e) => setUserName(e.target.value)}
                data-testid="transfer-create-user-name"
              />
              <p className="aws-hint">
                3–100 characters. Use letters, numbers, hyphens, underscores,
                periods, and @ symbols.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label">Server</label>
              <p style={{ margin: 0 }}>
                <code className="aws-mono">{serverId}</code>{' '}
                <span className="aws-quiet">· SFTP · Service managed</span>
              </p>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Identity provider</h2>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="identityProvider"
                    value="service-managed"
                    checked
                    onChange={() => undefined}
                    data-testid="transfer-idp-service-managed"
                  />
                  <span>
                    <strong>Service managed</strong>
                    <span className="sub">
                      Manage user credentials and SSH public keys in Transfer
                      Family.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="identityProvider"
                    value="custom"
                    disabled
                    aria-disabled="true"
                    title={TO_IMPLEMENT}
                  />
                  <span>
                    <strong>Custom identity provider</strong>
                    <span className="sub">
                      Authenticate through API Gateway, AWS Lambda, or AWS
                      Directory Service.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Permissions</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="role-arn">
                Role ARN <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="role-arn"
                name="roleArn"
                type="text"
                autoComplete="off"
                placeholder="arn:aws:iam::000000000000:role/TransferAccess"
                value={roleArn}
                onChange={(e) => setRoleArn(e.target.value)}
                data-testid="transfer-create-role"
              />
              <p className="aws-hint">
                The IAM role Transfer Family assumes for this user. It must
                trust <code className="aws-mono">transfer.amazonaws.com</code>.
              </p>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Home directory</h2>
            <div className="aws-field">
              <label className="aws-label">Home directory type</label>
              <ul className="aws-radio-list">
                <li>
                  <label>
                    <input
                      type="radio"
                      name="homeDirType"
                      value="PATH"
                      checked
                      onChange={() => undefined}
                      data-testid="transfer-home-path"
                    />
                    <span>
                      <strong>PATH</strong>
                      <span className="sub">
                        Map the user to an absolute path in the server&apos;s
                        storage.
                      </span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="homeDirType"
                      value="LOGICAL"
                      disabled
                      aria-disabled="true"
                      title={TO_IMPLEMENT}
                    />
                    <span>
                      <strong>LOGICAL</strong>
                      <span className="sub">
                        Map logical directories to S3 bucket paths.
                      </span>
                    </span>
                  </label>
                </li>
              </ul>
            </div>
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label" htmlFor="home-dir">
                Home directory
              </label>
              <input
                className="aws-input"
                id="home-dir"
                name="homeDirectory"
                type="text"
                autoComplete="off"
                placeholder="/my-user-home"
                value={homeDirectory}
                onChange={(e) => setHomeDirectory(e.target.value)}
                data-testid="transfer-create-home"
              />
              <p className="aws-hint">
                Optional. Leave blank to use the storage root for this user.
              </p>
            </div>
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label">Home directory mapping</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Add mapping…
              </button>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">
              SSH public key{' '}
              <span className="aws-quiet" style={{ fontSize: 13, fontWeight: 400 }}>
                Optional
              </span>
            </h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="ssh-key-body">
                Public key body
              </label>
              <textarea
                className="aws-input"
                id="ssh-key-body"
                name="sshPublicKeyBody"
                rows={5}
                placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI… user@host"
                spellCheck={false}
                style={{
                  height: 120,
                  padding: '8px 10px',
                  resize: 'vertical',
                  fontFamily: 'var(--font-mono)',
                  fontSize: 13,
                  lineHeight: 1.5,
                }}
                value={sshKey}
                onChange={(e) => setSshKey(e.target.value)}
                data-testid="transfer-create-ssh-key"
              />
              <p className="aws-hint">
                Paste the full public key including the algorithm prefix. You
                can add keys after the user is created.
              </p>
            </div>
            <div className="aws-field" style={{ marginTop: 12 }}>
              <label className="aws-label">Public key file</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Choose .pub file…
              </button>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">
              Additional settings{' '}
              <span className="aws-quiet" style={{ fontSize: 13, fontWeight: 400 }}>
                Optional
              </span>
            </h2>
            <div className="aws-field">
              <label className="aws-label">Tags</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Add tag…
              </button>
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
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="transfer-create-user-submit"
        >
          {busy ? 'Creating…' : 'Create user'}
        </button>
      </div>
    </>
  )
}
