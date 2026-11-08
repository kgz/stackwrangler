import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  ListCard,
  Notices,
  SelectCell,
  SelectHeader,
  SortHeader,
} from '../components/ServiceUi'
import { deleteTopic, listTopics, type SnsTopicRow } from '../lib/sns'

export function SnsTopicsPage() {
  const [topics, setTopics] = useState<SnsTopicRow[]>([])
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [busy, setBusy] = useState(false)

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

  const selectedTopic = useMemo(
    () => topics.find((t) => t.arn === selected) ?? null,
    [topics, selected],
  )

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onDelete() {
    if (!selectedTopic) return
    setBusy(true)
    setError(null)
    try {
      await deleteTopic(selectedTopic.arn)
      setConfirmDelete(false)
      setSelected(null)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <ListCard
        title="Topics"
        desc="Amazon Simple Notification Service (SNS) sends notifications two ways, A2A and A2P. A2A provides high-throughput, push-based, many-to-many messaging between distributed systems, microservices, and event-driven serverless applications."
        notices={<Notices error={error} />}
        toolbar={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selectedTopic || busy}
              title={selectedTopic ? undefined : 'Select a row'}
              onClick={() => setConfirmDelete(true)}
              data-testid="sns-delete"
            >
              Delete
            </button>
            <div className="spacer" />
            <Link className="btn btn-primary" to="/sns/create">
              Create topic
            </Link>
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
                        <Link
                          to={`/sns/topics/${encodeURIComponent(t.name)}`}
                          onClick={(e) => e.stopPropagation()}
                        >
                          {t.name}
                        </Link>
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

      {confirmDelete && selectedTopic ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete topic?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{selectedTopic.name}</strong>.
              Subscriptions on this topic are removed.
            </p>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setConfirmDelete(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onDelete()}
                data-testid="sns-confirm-delete"
              >
                {busy ? 'Deleting…' : 'Delete topic'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
