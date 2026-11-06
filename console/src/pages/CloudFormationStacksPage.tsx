import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  EmptyRow,
  FilterHeader,
  Kv,
  ListCard,
  Mono,
  Notices,
  PlainHeader,
  SelectCell,
  SelectHeader,
  SortHeader,
  StatusBadge,
  TabBar,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  deleteChangeSet,
  deleteStack,
  describeStack,
  executeChangeSet,
  getStackTemplate,
  listChangeSets,
  listStackEvents,
  listStackResources,
  listStacks,
  type ChangeSetSummary,
  type Output,
  type Parameter,
  type Stack,
  type StackEvent,
  type StackResource,
  type StackSummary,
} from '../lib/cfn'

type DetailTab = (typeof DETAIL_TABS)[number][0]

function UpdateMenu({
  stackName,
  disabled,
}: {
  stackName: string | null
  disabled?: boolean
}) {
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onDoc(e: MouseEvent) {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [open])

  const gated = !stackName || disabled
  const base = stackName
    ? `/cloudformation/stacks/${encodeURIComponent(stackName)}`
    : ''

  return (
    <div className="aws-pop" ref={rootRef}>
      <button
        type="button"
        className="btn btn-normal"
        disabled={gated}
        title={stackName ? undefined : 'Select a row'}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        Update ▾
      </button>
      {open && stackName ? (
        <div className="aws-menu open left" role="menu">
          <Link
            to={`${base}/update`}
            role="menuitem"
            onClick={() => setOpen(false)}
          >
            Update stack
          </Link>
          <Link
            to={`${base}/change-sets/create`}
            role="menuitem"
            onClick={() => setOpen(false)}
          >
            Create change set
          </Link>
        </div>
      ) : null}
    </div>
  )
}

function StacksList() {
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

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

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
    <ListCard
      title={
        <>
          Stacks{' '}
          <span className="aws-quiet">({loading ? '…' : filtered.length})</span>
        </>
      }
      notices={<Notices error={error} toast={toast} />}
      toolbar={
        <>
          <RefreshButton onClick={() => void refresh()} />
          <button
            type="button"
            className="btn btn-normal"
            disabled={!selected || busy}
            title={selected ? undefined : 'Select a row'}
            onClick={() => void onDelete()}
          >
            Delete
          </button>
          <UpdateMenu stackName={selected} disabled={busy} />
          <DeadButton>Stack actions ▾</DeadButton>
          <label className="field-inline">
            Filter status
            <select
              className="aws-select"
              value={includeDeleted ? 'all' : 'active'}
              onChange={(e) => setIncludeDeleted(e.target.value === 'all')}
            >
              <option value="active">Active</option>
              <option value="all">Active + deleted</option>
            </select>
          </label>
          <div className="spacer" />
          <DeadButton variant="primary">Create stack ▾</DeadButton>
        </>
      }
      placeholder="Search by stack name"
      filter={filter}
      onFilter={setFilter}
    >
      <table className="aws-table" data-testid="cfn-stacks-table">
        <thead>
          <tr>
            <SelectHeader />
            <SortHeader>Stack name</SortHeader>
            <FilterHeader>Status</FilterHeader>
            <SortHeader>Created time</SortHeader>
            <FilterHeader>Description</FilterHeader>
          </tr>
        </thead>
        <tbody>
          {filtered.length === 0 ? (
            <EmptyRow
              colSpan={5}
              loading={loading}
              loadingText="Loading stacks…"
              title="No stacks"
              text="No stacks to display."
            />
          ) : (
            filtered.map((s) => {
              const n = s.StackName ?? ''
              const isSelected = selected === n
              return (
                <tr
                  key={s.StackId ?? n}
                  className={`selectable${isSelected ? ' selected' : ''}`}
                  onClick={() => toggle(n)}
                >
                  <SelectCell
                    name="selected-stack"
                    id={n}
                    selected={isSelected}
                    onToggle={toggle}
                  />
                  <td>
                    <ResourceLabel ids={[n, s.StackId]}>
                      <Link
                        to={`/cloudformation/stacks/${encodeURIComponent(n)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {n}
                      </Link>
                    </ResourceLabel>
                  </td>
                  <td>
                    <StatusBadge status={s.StackStatus} />
                  </td>
                  <td>{formatServiceDate(s.CreationTime)}</td>
                  <td>{s.TemplateDescription ?? '—'}</td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </ListCard>
  )
}

const DETAIL_TABS = [
  ['info', 'Stack info'],
  ['events', 'Events'],
  ['resources', 'Resources'],
  ['outputs', 'Outputs'],
  ['parameters', 'Parameters'],
  ['template', 'Template'],
  ['changesets', 'Change sets'],
] as const

function ChangeSetsPanel({ stackName }: { stackName: string }) {
  const [sets, setSets] = useState<ChangeSetSummary[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const list = await listChangeSets(stackName)
      setSets(list)
      setSelected((cur) =>
        cur && list.some((s) => s.ChangeSetName === cur) ? cur : null,
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [stackName])

  useEffect(() => {
    void refresh()
  }, [refresh])

  function toggle(id: string) {
    setSelected((cur) => (cur === id ? null : id))
  }

  async function onExecute() {
    if (!selected) return
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      await executeChangeSet({
        stackName,
        changeSetName: selected,
      })
      setToast(`Execute started for ${selected}`)
      setSelected(null)
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onDelete() {
    if (!selected) return
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      await deleteChangeSet({
        stackName,
        changeSetName: selected,
      })
      setToast(`Deleted ${selected}`)
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
      <Notices error={error} toast={toast} />
      <div className="aws-toolbar" style={{ marginBottom: 12 }}>
        <RefreshButton onClick={() => void refresh()} />
        <button
          type="button"
          className="btn btn-normal"
          disabled={!selected || busy}
          title={selected ? undefined : 'Select a row'}
          onClick={() => void onExecute()}
        >
          Execute
        </button>
        <button
          type="button"
          className="btn btn-normal"
          data-testid="btn-delete-changeset"
          disabled={!selected || busy}
          title={selected ? undefined : 'Select a row'}
          onClick={() => void onDelete()}
        >
          Delete
        </button>
        <div className="spacer" />
        <Link
          className="btn btn-primary"
          to={`/cloudformation/stacks/${encodeURIComponent(stackName)}/change-sets/create`}
        >
          Create change set
        </Link>
      </div>
      <div className="aws-table-wrap">
        <table className="aws-table" data-testid="changesets-table">
          <thead>
            <tr>
              <SelectHeader />
              <PlainHeader>Change set name</PlainHeader>
              <PlainHeader>Status</PlainHeader>
              <PlainHeader>Execution status</PlainHeader>
              <PlainHeader>Creation time</PlainHeader>
            </tr>
          </thead>
          <tbody>
            {sets.length === 0 ? (
              <EmptyRow
                colSpan={5}
                loading={loading}
                loadingText="Loading change sets…"
                title="No change sets"
                text="This stack has no change sets."
              />
            ) : (
              sets.map((cs) => {
                const csName = cs.ChangeSetName ?? ''
                const isSelected = selected === csName
                return (
                  <tr
                    key={cs.ChangeSetId ?? csName}
                    className={`selectable${isSelected ? ' selected' : ''}`}
                    onClick={() => toggle(csName)}
                  >
                    <SelectCell
                      name="selected-changeset"
                      id={csName}
                      selected={isSelected}
                      onToggle={toggle}
                    />
                    <td>
                      <Link
                        to={`/cloudformation/stacks/${encodeURIComponent(stackName)}/change-sets/${encodeURIComponent(csName)}`}
                        onClick={(e) => e.stopPropagation()}
                      >
                        {csName}
                      </Link>
                    </td>
                    <td>
                      <StatusBadge status={cs.Status} />
                    </td>
                    <td>{cs.ExecutionStatus ?? '—'}</td>
                    <td>{formatServiceDate(cs.CreationTime)}</td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
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
    <div className="aws-detail-split">
      <aside className="aws-card">
        <div className="aws-card-body">
          <div className="aws-toolbar" style={{ marginBottom: 8 }}>
            <strong>Stacks ({siblings.length})</strong>
            <div className="spacer" />
            <RefreshButton onClick={() => void refresh()} />
          </div>
          <ul className="aws-rail-list">
            {siblings.map((s) => {
              const n = s.StackName ?? ''
              return (
                <li key={s.StackId ?? n}>
                  <Link
                    to={`/cloudformation/stacks/${encodeURIComponent(n)}`}
                    className={n === name ? 'active' : undefined}
                  >
                    <span className="rail-name">{n}</span>
                    <StatusBadge status={s.StackStatus} />
                  </Link>
                </li>
              )
            })}
          </ul>
        </div>
      </aside>

      <div>
        <div className="aws-toolbar">
          <div style={{ flex: 1, minWidth: 0 }}>
            <h1 className="aws-h1" style={{ margin: 0 }}>
              <ResourceLabel ids={[name, stack?.StackId]} detail>
                {name}
              </ResourceLabel>
            </h1>
            {stack ? (
              <div className="aws-subtitle-row">
                <StatusBadge status={stack.StackStatus} />
                <span>Created {formatServiceDate(stack.CreationTime)}</span>
              </div>
            ) : null}
          </div>
          <button
            type="button"
            className="btn btn-normal"
            disabled={busy}
            onClick={() => void onDelete()}
          >
            Delete
          </button>
          <UpdateMenu stackName={name} disabled={busy} />
          <DeadButton variant="primary">Create stack ▾</DeadButton>
        </div>

        <Notices error={error} toast={toast} />

        <section className="aws-card">
          <TabBar<DetailTab> tabs={DETAIL_TABS} active={tab} onChange={setTab} />
          <div className="aws-card-body">
            {loading && tab !== 'changesets' ? (
              <p className="aws-desc">Loading…</p>
            ) : tab === 'info' ? (
              <>
                <h2 className="aws-section-title">Overview</h2>
                <Kv
                  rows={[
                    ['Stack ID', <Mono key="id">{stack?.StackId ?? '—'}</Mono>],
                    ['Description', stack?.Description ?? '—'],
                    ['Created time', formatServiceDate(stack?.CreationTime)],
                    [
                      'Last updated time',
                      formatServiceDate(stack?.LastUpdatedTime),
                    ],
                    [
                      'Status',
                      <StatusBadge key="st" status={stack?.StackStatus} />,
                    ],
                    [
                      'Disable rollback',
                      stack?.DisableRollback ? 'true' : 'false',
                    ],
                  ]}
                />
                <h2 className="aws-section-title" style={{ marginTop: 20 }}>
                  Tags
                </h2>
                {tags.length === 0 ? (
                  <p className="aws-desc">No tags</p>
                ) : (
                  <div className="aws-table-wrap">
                    <table className="aws-table">
                      <thead>
                        <tr>
                          <PlainHeader>Key</PlainHeader>
                          <PlainHeader>Value</PlainHeader>
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
                  </div>
                )}
              </>
            ) : tab === 'events' ? (
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="events-table">
                  <thead>
                    <tr>
                      <PlainHeader>Timestamp</PlainHeader>
                      <PlainHeader>Logical ID</PlainHeader>
                      <PlainHeader>Status</PlainHeader>
                      <PlainHeader>Status reason</PlainHeader>
                      <PlainHeader>Type</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {events.length === 0 ? (
                      <EmptyRow
                        colSpan={5}
                        loading={false}
                        loadingText=""
                        title="No events"
                      />
                    ) : (
                      events.map((e) => (
                        <tr
                          key={
                            e.EventId ??
                            `${e.LogicalResourceId}-${e.Timestamp?.getTime()}`
                          }
                        >
                          <td>{formatServiceDate(e.Timestamp)}</td>
                          <td>{e.LogicalResourceId ?? '—'}</td>
                          <td>
                            <StatusBadge status={e.ResourceStatus} />
                          </td>
                          <td>{e.ResourceStatusReason ?? '—'}</td>
                          <td>{e.ResourceType ?? '—'}</td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            ) : tab === 'resources' ? (
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="resources-table">
                  <thead>
                    <tr>
                      <PlainHeader>Logical ID</PlainHeader>
                      <PlainHeader>Physical ID</PlainHeader>
                      <PlainHeader>Type</PlainHeader>
                      <PlainHeader>Status</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {resources.length === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={false}
                        loadingText=""
                        title="No resources"
                      />
                    ) : (
                      resources.map((r) => (
                        <tr key={r.LogicalResourceId}>
                          <td>{r.LogicalResourceId ?? '—'}</td>
                          <td>
                            <ResourceLabel ids={[r.PhysicalResourceId]}>
                              <Mono>{r.PhysicalResourceId ?? '—'}</Mono>
                            </ResourceLabel>
                          </td>
                          <td>{r.ResourceType ?? '—'}</td>
                          <td>
                            <StatusBadge status={r.ResourceStatus} />
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            ) : tab === 'outputs' ? (
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="outputs-table">
                  <thead>
                    <tr>
                      <PlainHeader>Key</PlainHeader>
                      <PlainHeader>Value</PlainHeader>
                      <PlainHeader>Description</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {outputs.length === 0 ? (
                      <EmptyRow
                        colSpan={3}
                        loading={false}
                        loadingText=""
                        title="No outputs"
                      />
                    ) : (
                      outputs.map((o) => (
                        <tr key={o.OutputKey}>
                          <td>{o.OutputKey ?? '—'}</td>
                          <td>
                            <Mono>{o.OutputValue ?? '—'}</Mono>
                          </td>
                          <td>{o.Description ?? '—'}</td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            ) : tab === 'parameters' ? (
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="parameters-table">
                  <thead>
                    <tr>
                      <PlainHeader>Key</PlainHeader>
                      <PlainHeader>Value</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {parameters.length === 0 ? (
                      <EmptyRow
                        colSpan={2}
                        loading={false}
                        loadingText=""
                        title="No parameters"
                      />
                    ) : (
                      parameters.map((p) => (
                        <tr key={p.ParameterKey}>
                          <td>{p.ParameterKey ?? '—'}</td>
                          <td>
                            <Mono>{p.ParameterValue ?? '—'}</Mono>
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            ) : tab === 'template' ? (
              <pre
                className="aws-mono"
                style={{ whiteSpace: 'pre-wrap', margin: 0 }}
              >
                {template || '(empty template)'}
              </pre>
            ) : (
              <ChangeSetsPanel stackName={name} />
            )}
          </div>
        </section>
      </div>
    </div>
  )
}

export function CloudFormationStacksPage() {
  const { name } = useParams<{ name?: string }>()
  if (name) {
    return <StackDetail name={decodeURIComponent(name)} />
  }
  return <StacksList />
}
