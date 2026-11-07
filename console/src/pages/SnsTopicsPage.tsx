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
import { listTopics, type SnsTopicRow } from '../lib/sns'

export function SnsTopicsPage() {
  const [topics, setTopics] = useState<SnsTopicRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listTopics()
      setTopics(list)
      setSelected((prev) =>
        prev && list.some((t) => t.arn === prev) ? prev : null,
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
    if (!q) return topics
    return topics.filter(
      (t) =>
        t.name.toLowerCase().includes(q) ||
        t.arn.toLowerCase().includes(q) ||
        t.type.toLowerCase().includes(q),
    )
  }, [topics, filter])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  return (
    <ListCard
      title="Topics"
      desc="Amazon Simple Notification Service (SNS) sends notifications two ways, A2A and A2P. A2A provides high-throughput, push-based, many-to-many messaging between distributed systems, microservices, and event-driven serverless applications."
      notices={<Notices error={error} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <DeadButton title={selected ? undefined : 'Select a row'}>
            Delete
          </DeadButton>
          <div className="spacer" />
          <DeadButton variant="primary">Create topic</DeadButton>
        </>
      }
      placeholder="Filter topics by name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="sns-topics-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Name</SortHeader>
            <FilterHeader>Type</FilterHeader>
            <SortHeader>ARN</SortHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={4}
              loading={loading}
              loadingText="Loading topics…"
              title="No topics"
              text="You do not have any topics in this region."
            />
          ) : (
            filtered.map((t) => {
              const isSelected = selected === t.arn
              return (
                <tr
                  key={t.arn}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(t.arn)}
                >
                  <SelectCell
                    name="selected-sns-topic"
                    id={t.arn}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[t.name, t.arn]} detail={isSelected}>
                      <DeadLink>{t.name}</DeadLink>
                    </ResourceLabel>
                  </td>
                  <td>{t.type}</td>
                  <td>{t.arn}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}
