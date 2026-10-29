import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  listUsers,
  runAccessDeniedLab,
  type AccessDeniedLabResult,
} from '../lib/iam'
import type { User } from '@aws-sdk/client-iam'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DeadLink,
  EmptyRow,
  FilterHeader,
  ListCard,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'

export function IamUsersPage() {
  const [users, setUsers] = useState<User[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
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

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return users
    return users.filter((u) => (u.UserName ?? '').toLowerCase().includes(q))
  }, [users, filter])

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

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Users"
      desc="An IAM user is an identity with long-term credentials used to interact with stackwrangler."
      notices={
        <>
          <Notices error={error} />
          {lab?.denied ? (
            <div className="toast-banner" role="status">
              AccessDenied — deny policy blocked <code>s3:ListAllMyBuckets</code>{' '}
              for lab user <code>{lab.userName}</code>.
              <pre className="lab-detail">{lab.message}</pre>
            </div>
          ) : null}
        </>
      }
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Delete</DeadButton>
          <button
            type="button"
            className="btn btn-normal"
            disabled={labBusy}
            onClick={() => void onRunLab()}
          >
            {labBusy ? 'Running lab…' : 'Run AccessDenied lab'}
          </button>
          <div className="spacer" />
          <DeadButton variant="primary">Create user</DeadButton>
        </>
      }
      placeholder="Search users"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="iam-users-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>User name</SortHeader>
            <FilterHeader>Groups</FilterHeader>
            <FilterHeader>Last activity</FilterHeader>
            <FilterHeader>Password age</FilterHeader>
            <FilterHeader>MFA</FilterHeader>
            <FilterHeader>Access key age</FilterHeader>
            <FilterHeader>Console last sign-in</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={8}
              loading={loading}
              loadingText="Loading users…"
              title="No users"
              text="You do not have any IAM users in this account yet."
            />
          ) : (
            filtered.map((u) => {
              const name = u.UserName ?? ''
              const isSelected = selected === name
              return (
                <tr
                  key={u.UserId ?? name}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(name)}
                >
                  <SelectCell
                    name="selected-user"
                    id={name}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[u.UserName, u.UserId, u.Arn]}>
                      <DeadLink>{name}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>—</td>
                  <td>{u.PasswordLastUsed ? formatServiceDate(u.PasswordLastUsed) : '—'}</td>
                  <td>—</td>
                  <td>—</td>
                  <td>—</td>
                  <td>{u.PasswordLastUsed ? formatServiceDate(u.PasswordLastUsed) : '—'}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
