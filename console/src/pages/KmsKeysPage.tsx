import { useCallback, useEffect, useMemo, useState } from 'react'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DeadLink,
  EmptyRow,
  FilterHeader,
  ListCard,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  listCustomerManagedKeys,
  type CustomerManagedKeyRow,
} from '../lib/kms'

export function KmsKeysPage() {
  const [keys, setKeys] = useState<CustomerManagedKeyRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listCustomerManagedKeys()
      setKeys(list)
      setSelected((prev) =>
        prev && list.some((k) => k.keyId === prev) ? prev : null,
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
    if (!q) return keys
    return keys.filter(
      (k) =>
        k.alias.toLowerCase().includes(q) ||
        k.keyId.toLowerCase().includes(q) ||
        k.status.toLowerCase().includes(q) ||
        k.keySpec.toLowerCase().includes(q) ||
        k.keyUsage.toLowerCase().includes(q),
    )
  }, [keys, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  const selectionTitle = selected ? 'To implement' : 'Select a row'

  return (
    <ListCard
      title="Customer managed keys"
      desc="Customer managed keys are KMS keys that you create, own, and manage. You control key policies, rotation, and when keys can be used for encrypt and decrypt operations."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton />
          <button
            type="button"
            className="btn btn-normal"
            disabled
            aria-disabled="true"
            title={selectionTitle}
          >
            Delete
          </button>
          <button
            type="button"
            className="btn btn-normal"
            disabled
            aria-disabled="true"
            title={selectionTitle}
          >
            Schedule key deletion
          </button>
          <div className="spacer" />
          <DeadButton variant="primary">Create key</DeadButton>
        </>
      }
      placeholder="Filter keys by alias or key ID"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="kms-keys-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Alias</SortHeader>
            <FilterHeader>Key ID</FilterHeader>
            <FilterHeader>Status</FilterHeader>
            <FilterHeader>Key spec</FilterHeader>
            <FilterHeader>Key usage</FilterHeader>
            <SortHeader>Creation date</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={7}
              loading={loading}
              loadingText="Loading customer managed keys…"
              title="No customer managed keys"
              text="You do not have any customer managed keys in this region."
            />
          ) : (
            filtered.map((k) => {
              const isSelected = selected === k.keyId
              const aliasLabel = k.alias === '—' ? k.keyId : k.alias
              return (
                <tr
                  key={k.keyId}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(k.keyId)}
                >
                  <SelectCell
                    name="selected-kms-key"
                    id={k.keyId}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[aliasLabel, k.keyId]} detail={isSelected}>
                      <DeadLink>{k.alias === '—' ? k.keyId : k.alias}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>
                    <Mono>{k.keyId}</Mono>
                  </td>
                  <td>{k.status}</td>
                  <td>{k.keySpec}</td>
                  <td>{k.keyUsage}</td>
                  <td>{formatServiceDate(k.creationDate)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
