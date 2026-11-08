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
import { formatServiceDate } from '../lib/format'
import {
  deleteRule,
  listRules,
  type EventBridgeRuleRow,
} from '../lib/events'

export function EventBridgeRulesPage() {
  const [rules, setRules] = useState<EventBridgeRuleRow[]>([])
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
      const list = await listRules()
      setRules(list)
      setSelected((prev) =>
        prev &&
        list.some((r) => (r.arn || `${r.eventBusName}/${r.name}`) === prev)
          ? prev
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

  const selectedRule = useMemo(
    () =>
      rules.find((r) => (r.arn || `${r.eventBusName}/${r.name}`) === selected) ??
      null,
    [rules, selected],
  )

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onDelete() {
    if (!selectedRule) return
    setBusy(true)
    setError(null)
    try {
      await deleteRule(selectedRule.name, selectedRule.eventBusName)
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
        title="Rules"
        desc="Amazon EventBridge rules match incoming events and route them to targets for processing."
        notices={<Notices error={error} />}
        toolbar={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!selectedRule || busy}
              title={selectedRule ? undefined : 'Select a row'}
              onClick={() => setConfirmDelete(true)}
              data-testid="events-delete"
            >
              Delete
            </button>
            <div className="spacer" />
            <Link className="btn btn-primary" to="/events/create">
              Create rule
            </Link>
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
                const id = r.arn || `${r.eventBusName}/${r.name}`
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
                        <Link
                          to={`/events/rules/${encodeURIComponent(r.name)}?bus=${encodeURIComponent(r.eventBusName)}`}
                          onClick={(e) => e.stopPropagation()}
                        >
                          {r.name}
                        </Link>
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

      {confirmDelete && selectedRule ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete rule?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{selectedRule.name}</strong> on bus{' '}
              <strong>{selectedRule.eventBusName}</strong>. Targets are removed
              first.
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
                data-testid="events-confirm-delete"
              >
                {busy ? 'Deleting…' : 'Delete rule'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
