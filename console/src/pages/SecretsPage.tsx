import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import type { SecretListEntry } from '@aws-sdk/client-secrets-manager'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  ListCard,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import { listSecrets } from '../lib/secrets'

export function SecretsPage() {
  const [secrets, setSecrets] = useState<SecretListEntry[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listSecrets()
      setSecrets(list)
      setSelected((prev) =>
        prev && list.some((s) => (s.ARN ?? s.Name) === prev) ? prev : null,
      )
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
    if (!q) return secrets
    return secrets.filter(
      (s) =>
        (s.Name ?? '').toLowerCase().includes(q) ||
        (s.Description ?? '').toLowerCase().includes(q) ||
        (s.ARN ?? '').toLowerCase().includes(q),
    )
  }, [secrets, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Secrets"
      desc="Secrets Manager helps you manage, retrieve, and rotate database credentials, application credentials, OAuth tokens, API keys, and other secrets throughout their lifecycles."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Delete</DeadButton>
          <DeadButton>Rotate</DeadButton>
          <div className="spacer" />
          <Link className="btn btn-primary" to="/secretsmanager/store">
            Store a new secret
          </Link>
        </>
      }
      placeholder="Filter secrets"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="secrets-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Description</FilterHeader>
            <FilterHeader>Last retrieved</FilterHeader>
            <SortHeader>Created on</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={5}
              loading={loading}
              loadingText="Loading secrets…"
              title="No secrets"
              text="You do not have any secrets in this region."
            />
          ) : (
            filtered.map((s) => {
              const arn = s.ARN ?? ''
              const name = s.Name ?? arn
              const id = arn || name
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-secret"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[name, arn]} detail={isSelected}>
                      <Link
                        to={`/secretsmanager/secrets/${name}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {name}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>{s.Description?.trim() ? s.Description : '—'}</td>
                  <td>{formatServiceDate(s.LastAccessedDate)}</td>
                  <td>{formatServiceDate(s.CreatedDate)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
