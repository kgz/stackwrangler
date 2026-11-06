import { useCallback, useEffect, useMemo, useState } from 'react'
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
  StatusBadge,
} from '../components/ServiceUi'
import { listStackSets, type StackSetSummary } from '../lib/cfn'

export function CloudFormationStackSetsPage() {
  const [sets, setSets] = useState<StackSetSummary[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listStackSets()
      setSets(list)
      setSelected((cur) =>
        cur && list.some((s) => (s.StackSetName ?? s.StackSetId) === cur)
          ? cur
          : null,
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
    if (!q) return sets
    return sets.filter((s) => {
      const name = (s.StackSetName ?? '').toLowerCase()
      const desc = (s.Description ?? '').toLowerCase()
      const status = (s.Status ?? '').toLowerCase()
      const perm = (s.PermissionModel ?? '').toLowerCase()
      return (
        name.includes(q) ||
        desc.includes(q) ||
        status.includes(q) ||
        perm.includes(q)
      )
    })
  }, [sets, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  const selectionTitle = selected ? 'To implement' : 'Select a row'

  return (
    <ListCard
      title="StackSets"
      desc="StackSets create, update, or delete stacks across accounts and Regions with one operation. LocalEmu ListStackSets is limited — CreateStackSet may succeed while the list stays empty (docs/cfn-stacksets-nested.md)."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <button
            type="button"
            className="btn btn-normal"
            disabled
            aria-disabled="true"
            title={selectionTitle}
          >
            Delete
          </button>
          <div className="spacer" />
          <DeadButton variant="primary">Create StackSet</DeadButton>
        </>
      }
      placeholder="Filter StackSets by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="cfn-stacksets-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>StackSet name</SortHeader>
            <FilterHeader>Description</FilterHeader>
            <FilterHeader>Status</FilterHeader>
            <FilterHeader>Permission model</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={5}
              loading={loading}
              loadingText="Loading StackSets…"
              title="No StackSets"
              text="You do not have any StackSets in this region. LocalEmu may accept CreateStackSet but ListStackSets often returns empty."
            />
          ) : (
            filtered.map((s) => {
              const name = s.StackSetName ?? s.StackSetId ?? ''
              const isSelected = selected === name
              return (
                <tr
                  key={s.StackSetId ?? name}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(name)}
                >
                  <SelectCell
                    name="selected-stackset"
                    id={name}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[name, s.StackSetId]}>
                      <DeadLink>{name || '—'}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>{s.Description ?? '—'}</td>
                  <td>
                    <StatusBadge status={s.Status} />
                  </td>
                  <td>{s.PermissionModel ?? '—'}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
