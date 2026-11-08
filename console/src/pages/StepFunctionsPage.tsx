import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import type { StateMachineListItem } from '@aws-sdk/client-sfn'
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
import { listStateMachines, typeLabel } from '../lib/sfn'

export function StepFunctionsPage() {
  const [machines, setMachines] = useState<StateMachineListItem[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listStateMachines()
      setMachines(list)
      setSelected((prev) =>
        prev && list.some((m) => m.stateMachineArn === prev) ? prev : null,
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
    if (!q) return machines
    return machines.filter(
      (m) =>
        (m.name ?? '').toLowerCase().includes(q) ||
        (m.stateMachineArn ?? '').toLowerCase().includes(q),
    )
  }, [machines, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="State machines"
      desc="A state machine is a workflow defined with states that perform work, make decisions, and control execution flow."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton>Actions ▾</DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create state machine</DeadButton>
        </>
      }
      placeholder="Filter by name or ARN"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="sfn-state-machines-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Type</FilterHeader>
            <SortHeader>Creation date</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={4}
              loading={loading}
              loadingText="Loading state machines…"
              title="No state machines"
              text="You do not have any state machines in this region."
            />
          ) : (
            filtered.map((m) => {
              const arn = m.stateMachineArn ?? ''
              const name = m.name ?? arn
              const isSelected = selected === arn
              return (
                <tr
                  key={arn || name}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(arn)}
                >
                  <SelectCell
                    name="selected-sfn"
                    id={arn}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[name, arn]} detail={isSelected}>
                      <Link
                        to={`/stepfunctions/state-machines/${encodeURIComponent(name)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {name}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>{typeLabel(m.type)}</td>
                  <td>{formatServiceDate(m.creationDate)}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
