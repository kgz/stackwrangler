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
  StatusBadge,
} from '../components/ServiceUi'
import { listTables, type DynamoDBTableRow } from '../lib/dynamodb'

export function DynamoDBTablesPage() {
  const [tables, setTables] = useState<DynamoDBTableRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listTables()
      setTables(list)
      setSelected((prev) =>
        prev && list.some((t) => t.name === prev) ? prev : null,
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
    if (!q) return tables
    return tables.filter(
      (t) =>
        t.name.toLowerCase().includes(q) ||
        t.status.toLowerCase().includes(q) ||
        t.partitionKey.toLowerCase().includes(q) ||
        t.sortKey.toLowerCase().includes(q) ||
        t.indexes.toLowerCase().includes(q) ||
        t.capacityMode.toLowerCase().includes(q),
    )
  }, [tables, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Tables"
      desc="Amazon DynamoDB is a fully managed NoSQL key-value and document database that delivers single-digit millisecond performance at any scale."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton title={selected ? undefined : 'Select a row'}>
            Delete
          </DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create table</DeadButton>
        </>
      }
      placeholder="Filter tables by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="dynamodb-tables-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Status</FilterHeader>
            <FilterHeader>Partition key</FilterHeader>
            <FilterHeader>Sort key</FilterHeader>
            <FilterHeader>Indexes</FilterHeader>
            <FilterHeader>Capacity mode</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={7}
              loading={loading}
              loadingText="Loading tables…"
              title="No tables"
              text="You do not have any tables in this region."
            />
          ) : (
            filtered.map((t) => {
              const isSelected = selected === t.name
              return (
                <tr
                  key={t.name}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(t.name)}
                >
                  <SelectCell
                    name="selected-dynamodb-table"
                    id={t.name}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[t.name]} detail={isSelected}>
                      <DeadLink>{t.name}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>
                    <StatusBadge status={t.status} />
                  </td>
                  <td>
                    <Mono>{t.partitionKey}</Mono>
                  </td>
                  <td>
                    {t.sortKey === '—' ? '—' : <Mono>{t.sortKey}</Mono>}
                  </td>
                  <td>{t.indexes}</td>
                  <td>{t.capacityMode}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
