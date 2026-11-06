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
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import { listRules, type EventBridgeRuleRow } from '../lib/events'

export function EventBridgeRulesPage() {
  const [rules, setRules] = useState<EventBridgeRuleRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listRules()
      setRules(list)
      setSelected((prev) =>
        prev && list.some((r) => (r.arn || r.name) === prev) ? prev : null,
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
    if (!q) return rules
    return rules.filter(
      (r) =>
        r.name.toLowerCase().includes(q) ||
        r.arn.toLowerCase().includes(q) ||
        r.status.toLowerCase().includes(q) ||
        r.eventBusName.toLowerCase().includes(q) ||
        r.type.toLowerCase().includes(q),
    )
  }, [rules, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Rules"
      desc="Amazon EventBridge rules match incoming events and route them to targets for processing."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton title={selected ? undefined : 'Select a row'}>
            Delete
          </DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create rule</DeadButton>
        </>
      }
      placeholder="Filter rules by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="eventbridge-rules-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Status</FilterHeader>
            <FilterHeader>Event bus</FilterHeader>
            <FilterHeader>Type</FilterHeader>
            <SortHeader>Updated</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={6}
              loading={loading}
              loadingText="Loading rules…"
              title="No rules"
              text="You do not have any rules in this region."
            />
          ) : (
            filtered.map((r) => {
              const id = r.arn || r.name
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-eventbridge-rule"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[r.name, r.arn]} detail={isSelected}>
                      <DeadLink>{r.name}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>{r.status}</td>
                  <td>{r.eventBusName}</td>
                  <td>{r.type}</td>
                  <td>{formatServiceDate(r.updatedOn)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
