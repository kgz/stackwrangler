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

function formatWhen(d: Date | undefined): string {
  if (!d) return '—'
  return d.toLocaleString()
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
        <span>CloudFormation</span> &gt; Stacks
      </div>
      <h1 className="page-title">Stacks ({loading ? '…' : filtered.length})</h1>
      <p className="page-lead">
        LocalEmu CloudFormation. Deploy with{' '}
        <code>./bin/cfn-smoke.sh</code> (or cdk/sam smokes) — Create stack in
        console is not wired yet.
      </p>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}

      <div className="panel">
        <div className="toolbar">
          <h3>Stacks</h3>
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn"
            disabled={!selected || busy}
            onClick={() => void onDelete()}
          >
            Delete stack
          </button>
          <button type="button" className="btn" disabled title="Use CLI / smokes">
            Update stack
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled
            title="Use ./bin/cfn-smoke.sh — no Create wizard yet"
          >
            Create stack
          </button>
        </div>

        <div className="toolbar-actions" style={{ marginBottom: 12 }}>
          <input
            type="search"
            placeholder="Search by stack name"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            aria-label="Search by stack name"
          />
          <label className="field-inline">
            <input
              type="checkbox"
              checked={includeDeleted}
              onChange={(e) => setIncludeDeleted(e.target.checked)}
            />
            Include deleted
          </label>
        </div>

        {loading ? (
          <p>Loading…</p>
        ) : filtered.length === 0 ? (
          <div className="empty">
            <strong>No stacks</strong>
            No stacks to display. Run a local smoke to create one.
            <div style={{ marginTop: 16 }}>
              <code>./bin/cfn-smoke.sh</code>
            </div>
          </div>
        ) : (
          <table className="data-table">
            <thead>
              <tr>
                <th />
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
                  >
                    <td>
                      <input
                        type="radio"
                        name="stack"
                        checked={selected === name}
                        aria-label={`Select ${name}`}
                        onChange={() => setSelected(name)}
                      />
                    </td>
                    <td>
                      <button
                        type="button"
                        className="btn-link"
                        onClick={() => navigate(`/cloudformation/stacks/${encodeURIComponent(name)}`)}
                      >
                        {name}
                      </button>
                    </td>
                    <td>
                      <span className="status-pill">{s.StackStatus ?? '—'}</span>
                    </td>
                    <td>{formatWhen(s.CreationTime)}</td>
                    <td>{s.TemplateDescription ?? '—'}</td>
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
  const [tab, setTab] = useState<DetailTab>('events')
  const [stack, setStack] = useState<Stack | null>(null)
  const [events, setEvents] = useState<StackEvent[]>([])
  const [resources, setResources] = useState<StackResource[]>([])
  const [template, setTemplate] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [st, ev, res, tpl] = await Promise.all([
        describeStack(name),
        listStackEvents(name),
        listStackResources(name),
        getStackTemplate(name),
      ])
      setStack(st)
      setEvents(ev)
      setResources(res)
      setTemplate(tpl)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const outputs: Output[] = stack?.Outputs ?? []
  const parameters: Parameter[] = stack?.Parameters ?? []

  return (
    <>
      <div className="crumbs">
        <Link to="/cloudformation">CloudFormation</Link> &gt;{' '}
        <Link to="/cloudformation">Stacks</Link> &gt; {name}
      </div>
      <h1 className="page-title">{name}</h1>
      {stack ? (
        <p className="page-lead">
          <span className="status-pill">{stack.StackStatus ?? '—'}</span>
          {' · '}
          Created {formatWhen(stack.CreationTime)}
        </p>
      ) : null}

      {error ? <div className="error-banner">{error}</div> : null}

      <div className="tabs">
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
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>

      <div className="panel">
        {loading ? (
          <p>Loading…</p>
        ) : tab === 'info' ? (
          <dl className="kv-list">
            <dt>Stack name</dt>
            <dd>{stack?.StackName ?? '—'}</dd>
            <dt>Stack ID</dt>
            <dd>
              <code>{stack?.StackId ?? '—'}</code>
            </dd>
            <dt>Status</dt>
            <dd>{stack?.StackStatus ?? '—'}</dd>
            <dt>Description</dt>
            <dd>{stack?.Description ?? '—'}</dd>
            <dt>Created</dt>
            <dd>{formatWhen(stack?.CreationTime)}</dd>
            <dt>Updated</dt>
            <dd>{formatWhen(stack?.LastUpdatedTime)}</dd>
          </dl>
        ) : tab === 'events' ? (
          <table className="data-table">
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
              {events.map((e) => (
                <tr key={e.EventId ?? `${e.LogicalResourceId}-${e.Timestamp?.getTime()}`}>
                  <td>{formatWhen(e.Timestamp)}</td>
                  <td>{e.LogicalResourceId ?? '—'}</td>
                  <td>{e.ResourceStatus ?? '—'}</td>
                  <td>{e.ResourceStatusReason ?? '—'}</td>
                  <td>{e.ResourceType ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : tab === 'resources' ? (
          <table className="data-table">
            <thead>
              <tr>
                <th>Logical ID</th>
                <th>Physical ID</th>
                <th>Type</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {resources.map((r) => (
                <tr key={r.LogicalResourceId}>
                  <td>{r.LogicalResourceId ?? '—'}</td>
                  <td>
                    <code>{r.PhysicalResourceId ?? '—'}</code>
                  </td>
                  <td>{r.ResourceType ?? '—'}</td>
                  <td>{r.ResourceStatus ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : tab === 'outputs' ? (
          outputs.length === 0 ? (
            <p className="empty-state">No outputs</p>
          ) : (
            <table className="data-table">
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
                    <td>{o.Description ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )
        ) : tab === 'parameters' ? (
          parameters.length === 0 ? (
            <p className="empty-state">No parameters</p>
          ) : (
            <table className="data-table">
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
          <pre className="lab-detail">{template || '(empty template)'}</pre>
        )}
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
