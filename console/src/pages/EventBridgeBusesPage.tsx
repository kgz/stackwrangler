import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
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
import { listEventBuses, type EventBridgeBusRow } from '../lib/events'

export function EventBridgeBusesPage() {
  const [buses, setBuses] = useState<EventBridgeBusRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listEventBuses()
      setBuses(list)
      setSelected((prev) =>
        prev && list.some((b) => (b.arn || b.name) === prev) ? prev : null,
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
    if (!q) return buses
    return buses.filter(
      (b) =>
        b.name.toLowerCase().includes(q) ||
        b.arn.toLowerCase().includes(q) ||
        b.type.toLowerCase().includes(q) ||
        b.description.toLowerCase().includes(q),
    )
  }, [buses, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Event buses"
      desc="An event bus receives events from sources and routes them to rules for matching and delivery."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton title={selected ? undefined : 'Select a row'}>
            Delete
          </DeadButton>
          <div className="spacer" />
          <Link className="btn btn-primary" to="/events/buses/create">
            Create event bus
          </Link>
        </>
      }
      placeholder="Filter event buses by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="eventbridge-buses-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Type</FilterHeader>
            <FilterHeader>Description</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={4}
              loading={loading}
              loadingText="Loading event buses…"
              title="No event buses"
              text="You do not have any custom event buses in this region."
            />
          ) : (
            filtered.map((b) => {
              const id = b.arn || b.name
              const isSelected = selected === id
              return (
                <tr
                  key={id}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(id)}
                >
                  <SelectCell
                    name="selected-eventbridge-bus"
                    id={id}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[b.name, b.arn]} detail={isSelected}>
                      {b.name}
                    </ResourceLabel>
                  </td>
                  <td>{b.type}</td>
                  <td>{b.description}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
