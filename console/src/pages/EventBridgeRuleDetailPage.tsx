import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { RefreshButton } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  Kv,
  Mono,
  Notices,
  SelectCell,
  SelectHeader,
  StatusBadge,
} from '../components/ServiceUi'
import {
  deleteRule,
  describeRule,
  listRuleTargets,
  putRuleTargets,
  removeRuleTargets,
  type EventBridgeRuleDetail,
  type EventBridgeTargetRow,
} from '../lib/events'

type DetailTab = 'details' | 'targets'

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['targets', 'Targets'],
]

export function EventBridgeRuleDetailPage() {
  const navigate = useNavigate()
  const { name: rawName } = useParams()
  const [search] = useSearchParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const eventBusName = search.get('bus')?.trim() || 'default'
  const [detail, setDetail] = useState<EventBridgeRuleDetail | null>(null)
  const [targets, setTargets] = useState<EventBridgeTargetRow[]>([])
  const [selectedTarget, setSelectedTarget] = useState<string | null>(null)
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)
  const [addOpen, setAddOpen] = useState(false)
  const [addError, setAddError] = useState<string | null>(null)
  const [targetId, setTargetId] = useState('1')
  const [targetArn, setTargetArn] = useState('')

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const rule = await describeRule(name, eventBusName)
      setDetail(rule)
      try {
        const list = await listRuleTargets(name, eventBusName)
        setTargets(list)
        setSelectedTarget((prev) =>
          prev && list.some((t) => t.id === prev) ? prev : null,
        )
      } catch {
        setTargets([])
        setSelectedTarget(null)
      }
    } catch (err) {
      setDetail(null)
      setTargets([])
      setSelectedTarget(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name, eventBusName])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const title = detail?.name ?? name

  function toggleTarget(id: string) {
    setSelectedTarget((cur) => (cur === id ? null : id))
  }

  async function onDelete() {
    if (!detail) return
    setBusy(true)
    setError(null)
    try {
      await deleteRule(detail.name, detail.eventBusName)
      navigate('/events')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  async function onRemoveTarget() {
    if (!detail || !selectedTarget) return
    setBusy(true)
    setError(null)
    try {
      await removeRuleTargets(detail.name, detail.eventBusName, [
        selectedTarget,
      ])
      setConfirmRemove(false)
      setSelectedTarget(null)
      setNotice(`Removed target ${selectedTarget}`)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmRemove(false)
    } finally {
      setBusy(false)
    }
  }

  async function onAddTarget() {
    if (!detail) return
    const id = targetId.trim()
    const arn = targetArn.trim()
    if (!id) {
      setAddError('Target id is required')
      return
    }
    if (!arn) {
      setAddError('Target ARN is required')
      return
    }
    setBusy(true)
    setAddError(null)
    setError(null)
    try {
      await putRuleTargets(detail.name, detail.eventBusName, [{ id, arn }])
      setAddOpen(false)
      setTargetArn('')
      setNotice(`Added target ${id}`)
      setTab('targets')
      await refresh()
    } catch (err) {
      setAddError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  function openAddTarget() {
    const nextId =
      targets.length === 0
        ? '1'
        : String(
            Math.max(
              ...targets.map((t) => Number.parseInt(t.id, 10) || 0),
              0,
            ) + 1,
          )
    setTargetId(nextId)
    setTargetArn('')
    setAddError(null)
    setNotice(null)
    setAddOpen(true)
  }

  return (
    <>
      <DetailHeader
        title={title}
        subtitle={
          <>
            <span>{detail?.status ?? '—'}</span>
            <span>{detail?.eventBusName ?? eventBusName}</span>
            <span>{detail?.type ?? '—'}</span>
          </>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={!detail || busy}
              onClick={() => setConfirmDelete(true)}
              data-testid="events-detail-delete"
            >
              Delete
            </button>
            {detail ? (
              <Link
                className="btn btn-primary"
                to={`/events/rules/${encodeURIComponent(detail.name)}/edit?bus=${encodeURIComponent(detail.eventBusName)}`}
                data-testid="events-detail-edit"
              >
                Edit
              </Link>
            ) : (
              <button
                type="button"
                className="btn btn-primary"
                disabled
                aria-disabled="true"
              >
                Edit
              </button>
            )}
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/events">← Rules</Link>
      </p>
      <Notices error={error} toast={notice} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          {TABS.map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`aws-tab${tab === id ? ' active' : ''}`}
              aria-current={tab === id ? 'page' : undefined}
              onClick={() => setTab(id)}
              data-testid={`events-tab-${id}`}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="aws-card-body">
          {loading && !detail ? <p className="aws-desc">Loading…</p> : null}

          {tab === 'details' && detail ? (
            <>
              <h2 className="aws-section-title">Rule details</h2>
              <Kv
                rows={[
                  ['Name', detail.name],
                  ['ARN', <Mono key="arn">{detail.arn}</Mono>],
                  [
                    'Status',
                    <StatusBadge
                      key="status"
                      status={detail.status}
                      label={detail.status}
                    />,
                  ],
                  ['Event bus', detail.eventBusName],
                  ['Type', detail.type],
                  ['Description', detail.description],
                  [
                    'Event pattern',
                    detail.eventPattern ? (
                      <pre
                        key="pattern"
                        className="aws-mono"
                        style={{ margin: 0, whiteSpace: 'pre-wrap' }}
                        data-testid="events-rule-pattern"
                      >
                        {detail.eventPattern}
                      </pre>
                    ) : (
                      '—'
                    ),
                  ],
                  [
                    'Schedule expression',
                    detail.scheduleExpression ? (
                      <Mono key="schedule">{detail.scheduleExpression}</Mono>
                    ) : (
                      '—'
                    ),
                  ],
                ]}
              />
            </>
          ) : null}

          {tab === 'targets' ? (
            <>
              <h2 className="aws-section-title">Targets</h2>
              <p className="aws-desc">
                Targets from LocalEmu <code>ListTargetsByRule</code>.
              </p>
              <div className="aws-toolbar" style={{ marginBottom: 12 }}>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={!selectedTarget || busy}
                  title={selectedTarget ? undefined : 'Select a row'}
                  onClick={() => setConfirmRemove(true)}
                  data-testid="events-remove-target"
                >
                  Remove
                </button>
                <div className="spacer" />
                <button
                  type="button"
                  className="btn btn-primary"
                  disabled={!detail || busy}
                  onClick={openAddTarget}
                  data-testid="events-add-target"
                >
                  Add target
                </button>
              </div>
              <table className="aws-table" data-testid="events-targets-table">
                <thead>
                  <tr>
                    <SelectHeader />
                    <th scope="col">
                      <span className="th-inner">Id</span>
                    </th>
                    <th scope="col">
                      <span className="th-inner">ARN</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {targets.length === 0 ? (
                    <EmptyRow
                      colSpan={3}
                      loading={loading}
                      loadingText="Loading targets…"
                      title="No targets"
                      text="This rule has no targets."
                    />
                  ) : (
                    targets.map((t) => {
                      const id = t.id || t.arn
                      const isSelected = selectedTarget === t.id
                      return (
                        <tr
                          key={id}
                          className={`selectable${isSelected ? ' selected' : ''}`}
                          onClick={() => {
                            if (t.id) toggleTarget(t.id)
                          }}
                        >
                          <SelectCell
                            name="selected-events-target"
                            id={t.id || id}
                            selected={isSelected}
                            onToggle={toggleTarget}
                          />
                          <td>{t.id || '—'}</td>
                          <td>
                            <Mono>{t.arn || '—'}</Mono>
                          </td>
                        </tr>
                      )
                    })
                  )}
                </tbody>
              </table>
            </>
          ) : null}
        </div>
      </section>

      {confirmDelete && detail ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete rule?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{detail.name}</strong>. Targets are
              removed first.
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

      {confirmRemove && selectedTarget ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Remove target?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Remove target <strong>{selectedTarget}</strong> from this rule.
            </p>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setConfirmRemove(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onRemoveTarget()}
                data-testid="events-confirm-remove-target"
              >
                {busy ? 'Removing…' : 'Remove target'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {addOpen && detail ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            style={{ maxWidth: 560, width: '100%' }}
            data-testid="events-add-target-modal"
          >
            <h3>Add target</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Put a target on <strong>{detail.name}</strong> via LocalEmu{' '}
              <code>PutTargets</code>.
            </p>
            {addError ? <div className="error-banner">{addError}</div> : null}
            <div className="aws-form-stack" style={{ marginTop: 12 }}>
              <div className="aws-field">
                <label className="aws-label" htmlFor="target-id">
                  Id <span className="req">*</span>
                </label>
                <input
                  className="aws-input"
                  id="target-id"
                  value={targetId}
                  onChange={(e) => setTargetId(e.target.value)}
                  data-testid="events-add-target-id"
                />
              </div>
              <div className="aws-field">
                <label className="aws-label" htmlFor="target-arn">
                  ARN <span className="req">*</span>
                </label>
                <input
                  className="aws-input"
                  id="target-arn"
                  value={targetArn}
                  onChange={(e) => setTargetArn(e.target.value)}
                  placeholder="arn:aws:lambda:us-east-1:000000000000:function:my-fn"
                  data-testid="events-add-target-arn"
                />
              </div>
            </div>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setAddOpen(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onAddTarget()}
                data-testid="events-add-target-submit"
              >
                {busy ? 'Adding…' : 'Add target'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
