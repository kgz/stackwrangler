import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import {
  deleteStack,
  describeStack,
  getStackTemplate,
  listStackEvents,
  listStackResources,
  listStacks,
  type Output,
  type Parameter,
  type Stack,
  type StackEvent,
  type StackResource,
  type StackSummary,
} from '../lib/cfn'

type DetailTab =
  | 'info'
  | 'events'
  | 'resources'
  | 'outputs'
  | 'parameters'
  | 'template'

type StatusKind = 'success' | 'error' | 'progress' | 'neutral'

function formatWhen(d: Date | undefined): string {
  if (!d) return '—'
  return d.toLocaleString()
}

function statusKind(status: string | undefined): StatusKind {
  if (!status) return 'neutral'
  if (status.includes('COMPLETE') && !status.includes('ROLLBACK') && !status.includes('FAILED')) {
    if (status.startsWith('DELETE')) return 'neutral'
    return 'success'
  }
  if (status.includes('FAILED') || status.includes('ROLLBACK')) return 'error'
  if (status.includes('IN_PROGRESS') || status.includes('PENDING')) return 'progress'
  return 'neutral'
}

function StatusBadge({ status }: { status: string | undefined }) {
  const kind = statusKind(status)
  return (
    <span className={`cfn-status cfn-status-${kind}`}>
      <span className="cfn-status-mark" aria-hidden />
      {status ?? '—'}
    </span>
  )
}

function StacksList() {
  const navigate = useNavigate()
  const [stacks, setStacks] = useState<StackSummary[]>([])
  const [filter, setFilter] = useState('')
  const [includeDeleted, setIncludeDeleted] = useState(false)
  const [selected, setSelected] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listStacks(includeDeleted)
      setStacks(list)
      setSelected((cur) =>
        cur && list.some((s) => s.StackName === cur) ? cur : null,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [includeDeleted])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return stacks
    return stacks.filter((s) => (s.StackName ?? '').toLowerCase().includes(q))
  }, [stacks, filter])

  async function onDelete() {
    if (!selected) return
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      await deleteStack(selected)
      setToast(`Delete started for ${selected}`)
      setSelected(null)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <div className="crumbs">
        <span>CloudFormation</span>
        <span className="crumbs-sep">/</span>
        <span>Stacks</span>
      </div>

      <div className="cfn-page-head">
        <h1 className="page-title">
          Stacks ({loading ? '…' : filtered.length})
        </h1>
        <div className="cfn-page-actions">
          <button
            type="button"
            className="btn btn-icon"
            aria-label="Refresh"
            title="Refresh"
            onClick={() => void refresh()}
          >
            ↻
          </button>
          <button
            type="button"
            className="btn"
            disabled={!selected || busy}
            onClick={() => void onDelete()}
          >
            Delete stack
          </button>
          <button type="button" className="btn" disabled title="Not wired yet">
            Update stack ▾
          </button>
          <button type="button" className="btn" disabled title="Not wired yet">
            Stack actions ▾
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled
            title="Use ./bin/cfn-smoke.sh"
          >
            Create stack ▾
          </button>
        </div>
      </div>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}

      <div className="panel">
        <div className="filters cfn-filters">
          <input
            type="search"
            placeholder="Search by stack name"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            aria-label="Search by stack name"
          />
          <label className="cfn-filter-status">
            Filter status
            <select
              value={includeDeleted ? 'all' : 'active'}
              onChange={(e) => setIncludeDeleted(e.target.value === 'all')}
            >
              <option value="active">Active</option>
              <option value="all">Active + deleted</option>
            </select>
          </label>
        </div>

        {loading ? (
          <div className="cfn-loading">Loading stacks…</div>
        ) : filtered.length === 0 ? (
          <div className="empty">
            <strong>No stacks</strong>
            No stacks to display.
            <div className="empty-hint">
              Create one with <code>./bin/cfn-smoke.sh</code>
            </div>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th className="col-check" aria-label="Select" />
                <th>Stack name</th>
                <th>Status</th>
                <th>Created time</th>
                <th>Description</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((s) => {
                const name = s.StackName ?? ''
                return (
                  <tr
                    key={s.StackId ?? name}
                    className={selected === name ? 'row-selected' : undefined}
                    onClick={() => setSelected(name)}
                  >
                    <td className="col-check" onClick={(e) => e.stopPropagation()}>
                      <input
                        type="radio"
                        name="stack"
                        checked={selected === name}
                        aria-label={`Select ${name}`}
                        onChange={() => setSelected(name)}
                      />
                    </td>
                    <td>
                      <Link
                        className="cfn-stack-link"
                        to={`/cloudformation/stacks/${encodeURIComponent(name)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {name}
                      </Link>
                    </td>
                    <td>
                      <StatusBadge status={s.StackStatus} />
                    </td>
                    <td className="cfn-muted">{formatWhen(s.CreationTime)}</td>
                    <td className="cfn-muted">
                      {s.TemplateDescription ?? '—'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}

function StackDetail({ name }: { name: string }) {
  const navigate = useNavigate()
  const [tab, setTab] = useState<DetailTab>('info')
  const [stack, setStack] = useState<Stack | null>(null)
  const [siblings, setSiblings] = useState<StackSummary[]>([])
  const [events, setEvents] = useState<StackEvent[]>([])
  const [resources, setResources] = useState<StackResource[]>([])
  const [template, setTemplate] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [st, ev, res, tpl, list] = await Promise.all([
        describeStack(name),
        listStackEvents(name),
        listStackResources(name),
        getStackTemplate(name),
        listStacks(false),
      ])
      setStack(st)
      setEvents(ev)
      setResources(res)
      setTemplate(tpl)
      setSiblings(list)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onDelete() {
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      await deleteStack(name)
      setToast(`Delete started for ${name}`)
      navigate('/cloudformation')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const outputs: Output[] = stack?.Outputs ?? []
  const parameters: Parameter[] = stack?.Parameters ?? []
  const tags = stack?.Tags ?? []

  return (
    <>
      <div className="crumbs">
        <Link to="/cloudformation">CloudFormation</Link>
        <span className="crumbs-sep">/</span>
        <Link to="/cloudformation">Stacks</Link>
        <span className="crumbs-sep">/</span>
        <span>{name}</span>
      </div>

      <div className="cfn-split">
        <aside className="cfn-rail panel">
          <div className="cfn-rail-head">
            <strong>Stacks ({siblings.length})</strong>
            <button
              type="button"
              className="btn btn-icon"
              aria-label="Refresh list"
              onClick={() => void refresh()}
            >
              ↻
            </button>
          </div>
          <ul className="cfn-rail-list">
            {siblings.map((s) => {
              const n = s.StackName ?? ''
              return (
                <li key={s.StackId ?? n}>
                  <Link
                    to={`/cloudformation/stacks/${encodeURIComponent(n)}`}
                    className={n === name ? 'active' : undefined}
                  >
                    <span className="cfn-rail-name">{n}</span>
                    <StatusBadge status={s.StackStatus} />
                  </Link>
                </li>
              )
            })}
          </ul>
        </aside>

        <div className="cfn-detail">
          <div className="cfn-page-head">
            <div>
              <h1 className="page-title">{name}</h1>
              {stack ? (
                <div className="cfn-subtitle">
                  <StatusBadge status={stack.StackStatus} />
                  <span className="cfn-muted">
                    {formatWhen(stack.CreationTime)}
                  </span>
                </div>
              ) : null}
            </div>
            <div className="cfn-page-actions">
              <button
                type="button"
                className="btn"
                disabled={busy}
                onClick={() => void onDelete()}
              >
                Delete stack
              </button>
              <button type="button" className="btn" disabled>
                Update stack ▾
              </button>
              <button type="button" className="btn" disabled>
                Stack actions ▾
              </button>
              <button type="button" className="btn btn-primary" disabled>
                Create stack ▾
              </button>
            </div>
          </div>

          {error ? <div className="error-banner">{error}</div> : null}
          {toast ? (
            <div className="toast-banner" role="status">
              {toast}
            </div>
          ) : null}

          <div className="tabs cfn-tabs">
            {(
              [
                ['info', 'Stack info'],
                ['events', 'Events'],
                ['resources', 'Resources'],
                ['outputs', 'Outputs'],
                ['parameters', 'Parameters'],
                ['template', 'Template'],
              ] as const
            ).map(([id, label]) => (
              <button
                key={id}
                type="button"
                className={tab === id ? 'active' : undefined}
                onClick={() => setTab(id)}
              >
                {label}
              </button>
            ))}
          </div>

          <div className="panel cfn-detail-panel">
            {loading ? (
              <div className="cfn-loading">Loading…</div>
            ) : tab === 'info' ? (
              <div className="cfn-overview">
                <section>
                  <h2 className="cfn-section-title">Overview</h2>
                  <dl className="cfn-kv">
                    <div>
                      <dt>Stack ID</dt>
                      <dd>
                        <code className="cfn-arn">{stack?.StackId ?? '—'}</code>
                      </dd>
                    </div>
                    <div>
                      <dt>Description</dt>
                      <dd>{stack?.Description ?? '—'}</dd>
                    </div>
                    <div>
                      <dt>Created time</dt>
                      <dd>{formatWhen(stack?.CreationTime)}</dd>
                    </div>
                    <div>
                      <dt>Last updated time</dt>
                      <dd>{formatWhen(stack?.LastUpdatedTime)}</dd>
                    </div>
                    <div>
                      <dt>Status</dt>
                      <dd>
                        <StatusBadge status={stack?.StackStatus} />
                      </dd>
                    </div>
                    <div>
                      <dt>Disable rollback</dt>
                      <dd>{stack?.DisableRollback ? 'true' : 'false'}</dd>
                    </div>
                  </dl>
                </section>

                <section>
                  <h2 className="cfn-section-title">Tags</h2>
                  {tags.length === 0 ? (
                    <p className="cfn-muted">No tags</p>
                  ) : (
                    <table className="data">
                      <thead>
                        <tr>
                          <th>Key</th>
                          <th>Value</th>
                        </tr>
                      </thead>
                      <tbody>
                        {tags.map((t) => (
                          <tr key={t.Key}>
                            <td>{t.Key}</td>
                            <td>{t.Value}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                </section>
              </div>
            ) : tab === 'events' ? (
              <table className="data">
                <thead>
                  <tr>
                    <th>Timestamp</th>
                    <th>Logical ID</th>
                    <th>Status</th>
                    <th>Status reason</th>
                    <th>Type</th>
                  </tr>
                </thead>
                <tbody>
                  {events.length === 0 ? (
                    <tr>
                      <td colSpan={5} className="cfn-muted">
                        No events
                      </td>
                    </tr>
                  ) : (
                    events.map((e) => (
                      <tr
                        key={
                          e.EventId ??
                          `${e.LogicalResourceId}-${e.Timestamp?.getTime()}`
                        }
                      >
                        <td className="cfn-muted">{formatWhen(e.Timestamp)}</td>
                        <td>{e.LogicalResourceId ?? '—'}</td>
                        <td>
                          <StatusBadge status={e.ResourceStatus} />
                        </td>
                        <td className="cfn-muted">
                          {e.ResourceStatusReason ?? '—'}
                        </td>
                        <td className="cfn-muted">{e.ResourceType ?? '—'}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            ) : tab === 'resources' ? (
              <table className="data">
                <thead>
                  <tr>
                    <th>Logical ID</th>
                    <th>Physical ID</th>
                    <th>Type</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {resources.length === 0 ? (
                    <tr>
                      <td colSpan={4} className="cfn-muted">
                        No resources
                      </td>
                    </tr>
                  ) : (
                    resources.map((r) => (
                      <tr key={r.LogicalResourceId}>
                        <td>{r.LogicalResourceId ?? '—'}</td>
                        <td>
                          <code>{r.PhysicalResourceId ?? '—'}</code>
                        </td>
                        <td className="cfn-muted">{r.ResourceType ?? '—'}</td>
                        <td>
                          <StatusBadge status={r.ResourceStatus} />
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            ) : tab === 'outputs' ? (
              outputs.length === 0 ? (
                <div className="empty">
                  <strong>No outputs</strong>
                </div>
              ) : (
                <table className="data">
                  <thead>
                    <tr>
                      <th>Key</th>
                      <th>Value</th>
                      <th>Description</th>
                    </tr>
                  </thead>
                  <tbody>
                    {outputs.map((o) => (
                      <tr key={o.OutputKey}>
                        <td>{o.OutputKey ?? '—'}</td>
                        <td>
                          <code>{o.OutputValue ?? '—'}</code>
                        </td>
                        <td className="cfn-muted">{o.Description ?? '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )
            ) : tab === 'parameters' ? (
              parameters.length === 0 ? (
                <div className="empty">
                  <strong>No parameters</strong>
                </div>
              ) : (
                <table className="data">
                  <thead>
                    <tr>
                      <th>Key</th>
                      <th>Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    {parameters.map((p) => (
                      <tr key={p.ParameterKey}>
                        <td>{p.ParameterKey ?? '—'}</td>
                        <td>
                          <code>{p.ParameterValue ?? '—'}</code>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )
            ) : (
              <pre className="cfn-template">{template || '(empty template)'}</pre>
            )}
          </div>
        </div>
      </div>
    </>
  )
}

export function CloudFormationStacksPage() {
  const { name } = useParams<{ name?: string }>()
  if (name) {
    return <StackDetail name={decodeURIComponent(name)} />
  }
  return <StacksList />
}
