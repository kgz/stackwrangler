import { useCallback, useEffect, useState } from 'react'
import {
  listUsers,
  runAccessDeniedLab,
  type AccessDeniedLabResult,
} from '../lib/iam'
import type { User } from '@aws-sdk/client-iam'

export function IamUsersPage() {
  const [users, setUsers] = useState<User[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [labBusy, setLabBusy] = useState(false)
  const [lab, setLab] = useState<AccessDeniedLabResult | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setUsers(await listUsers())
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onRunLab() {
    setLabBusy(true)
    setLab(null)
    setError(null)
    try {
      const result = await runAccessDeniedLab()
      setLab(result)
      if (!result.denied) {
        setError(result.message)
      }
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLabBusy(false)
    }
  }

  return (
    <div>
      <h1>Users</h1>
      <p className="page-lead">
        IAM users on the local IAM API. General purpose buckets still use
        SeaweedFS; the AccessDenied lab exercises policy enforcement on the
        IAM endpoint S3.
      </p>

      {error ? <div className="error-banner">{error}</div> : null}
      {lab?.denied ? (
        <div className="toast-banner" role="status">
          AccessDenied — deny policy blocked <code>s3:ListAllMyBuckets</code>{' '}
          for lab user <code>{lab.userName}</code>.
          <pre className="lab-detail">{lab.message}</pre>
        </div>
      ) : null}

      <div className="toolbar toolbar-stack">
        <h3>Users ({users.length})</h3>
        <div className="toolbar-actions">
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={labBusy}
            onClick={() => void onRunLab()}
          >
            {labBusy ? 'Running lab…' : 'Run AccessDenied lab'}
          </button>
        </div>
      </div>

      {loading ? (
        <p>Loading…</p>
      ) : users.length === 0 ? (
        <p className="empty-state">No users</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th>User name</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.UserId ?? u.UserName}>
                <td>{u.UserName}</td>
                <td>
                  {u.CreateDate
                    ? new Date(u.CreateDate).toLocaleString()
                    : '—'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}
