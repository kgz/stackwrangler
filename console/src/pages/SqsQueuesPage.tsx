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
import { listQueues, type SqsQueueRow } from '../lib/sqs'

export function SqsQueuesPage() {
  const [queues, setQueues] = useState<SqsQueueRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listQueues()
      setQueues(list)
      setSelected((prev) =>
        prev && list.some((q) => q.url === prev) ? prev : null,
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
    if (!q) return queues
    return queues.filter(
      (row) =>
        row.name.toLowerCase().includes(q) ||
        row.url.toLowerCase().includes(q) ||
        row.type.toLowerCase().includes(q),
    )
  }, [queues, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Queues"
      desc="Amazon Simple Queue Service (SQS) lets you send, store, and receive messages between software components at any volume, without losing messages or requiring other services to be available."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton title={selected ? undefined : 'Select a row'}>
            Delete
          </DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create queue</DeadButton>
        </>
      }
      placeholder="Filter queues by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="sqs-queues-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Type</FilterHeader>
            <SortHeader>Created</SortHeader>
            <SortHeader>Messages available</SortHeader>
            <SortHeader>Messages in flight</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={6}
              loading={loading}
              loadingText="Loading queues…"
              title="No queues"
              text="You do not have any queues in this region."
            />
          ) : (
            filtered.map((row) => {
              const isSelected = selected === row.url
              return (
                <tr
                  key={row.url}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(row.url)}
                >
                  <SelectCell
                    name="selected-sqs-queue"
                    id={row.url}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[row.name, row.url]} detail={isSelected}>
                      <DeadLink>{row.name}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>{row.type}</td>
                  <td>{formatServiceDate(row.createdOn)}</td>
                  <td>{row.messagesAvailable}</td>
                  <td>{row.messagesInFlight}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
