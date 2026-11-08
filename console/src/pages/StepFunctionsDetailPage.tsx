import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  Kv,
  Mono,
  Notices,
  PlainHeader,
  StatusBadge,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  describeStateMachine,
  listExecutions,
  prettyDefinition,
  startExecution,
  typeLabel,
  type ExecutionListItem,
  type StateMachineDetail,
} from '../lib/sfn'

type DetailTab = 'details' | 'definition' | 'executions'

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['definition', 'Definition'],
  ['executions', 'Executions'],
]

const DEFAULT_INPUT = '{\n  \n}'

function executionStatusLabel(status: string | undefined): string {
  if (!status) return '—'
  if (status === 'SUCCEEDED') return 'Succeeded'
  if (status === 'FAILED') return 'Failed'
  if (status === 'RUNNING') return 'Running'
  if (status === 'TIMED_OUT') return 'Timed out'
  if (status === 'ABORTED') return 'Aborted'
  return status
}

export function StepFunctionsDetailPage() {
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<StateMachineDetail | null>(null)
  const [executions, setExecutions] = useState<ExecutionListItem[]>([])
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [startError, setStartError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [starting, setStarting] = useState(false)
  const [showStart, setShowStart] = useState(false)
  const [execName, setExecName] = useState('')
  const [execInput, setExecInput] = useState(DEFAULT_INPUT)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const sm = await describeStateMachine(name)
      setDetail(sm)
      try {
        setExecutions(await listExecutions(sm.stateMachineArn))
      } catch {
        setExecutions([])
      }
    } catch (err) {
      setDetail(null)
      setExecutions([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  function openStart() {
    setExecName('')
    setExecInput(DEFAULT_INPUT)
    setStartError(null)
    setShowStart(true)
  }

  async function onStart() {
    if (!detail) return
    setBusy(true)
    setStartError(null)
    setToast(null)
    setStarting(true)
    try {
      const result = await startExecution({
        stateMachineArn: detail.stateMachineArn,
        name: execName,
        input: execInput,
      })
      setShowStart(false)
      setStartError(null)
      setTab('executions')
      setToast(`Started ${result.executionArn.split(':').pop() ?? 'execution'}`)
      await refresh()
    } catch (err) {
      setStartError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
      setStarting(false)
    }
  }

  const title = detail?.name ?? name

  return (
    <>
      <DetailHeader
        title={title}
        subtitle={
          <>
            <span>{typeLabel(detail?.type)}</span>
            <span>{detail?.status ?? '—'}</span>
            <span>Created {formatServiceDate(detail?.creationDate)}</span>
          </>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <DeadButton>Actions ▾</DeadButton>
            <button
              type="button"
              className="btn btn-primary"
              data-testid="sfn-start-execution"
              disabled={!detail || busy}
              onClick={openStart}
            >
              Start execution
            </button>
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/stepfunctions">← State machines</Link>
      </p>
      <Notices error={error} toast={toast} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          {TABS.map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`aws-tab${tab === id ? ' active' : ''}`}
              aria-current={tab === id ? 'page' : undefined}
              onClick={() => setTab(id)}
              data-testid={`sfn-tab-${id}`}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="aws-card-body">
          {loading && !detail ? <p className="aws-desc">Loading…</p> : null}

          {tab === 'details' && detail ? (
            <>
              <h2 className="aws-section-title">State machine details</h2>
              <Kv
                rows={[
                  ['Name', detail.name],
                  [
                    'ARN',
                    <Mono key="arn">{detail.stateMachineArn}</Mono>,
                  ],
                  ['Type', typeLabel(detail.type)],
                  [
                    'Status',
                    <StatusBadge
                      key="status"
                      status={detail.status}
                      label={detail.status}
                    />,
                  ],
                  [
                    'Execution role',
                    detail.roleArn ? (
                      <Mono key="role">{detail.roleArn}</Mono>
                    ) : (
                      '—'
                    ),
                  ],
                  ['Created', formatServiceDate(detail.creationDate)],
                ]}
              />
            </>
          ) : null}

          {tab === 'definition' && detail ? (
            <>
              <h2 className="aws-section-title">Definition</h2>
              <p className="aws-desc">
                Amazon States Language for this state machine.
              </p>
              <pre
                className="aws-mono"
                data-testid="sfn-definition"
                style={{
                  margin: 0,
                  padding: 12,
                  background: 'var(--aws-surface-2, #f6f5f4)',
                  border: '1px solid var(--aws-border, #d5d0cd)',
                  borderRadius: 4,
                  overflow: 'auto',
                  fontSize: 12,
                  lineHeight: 1.45,
                }}
              >
                {prettyDefinition(detail.definition)}
              </pre>
            </>
          ) : null}

          {tab === 'executions' ? (
            <>
              <div className="aws-toolbar">
                <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
                  Executions
                </h2>
                <button
                  type="button"
                  className="btn btn-normal"
                  data-testid="sfn-start-execution-tab"
                  disabled={!detail || busy}
                  onClick={openStart}
                >
                  Start execution
                </button>
              </div>
              <div className="aws-table-wrap">
                <table
                  className="aws-table"
                  data-testid="sfn-executions-table"
                >
                  <thead>
                    <tr>
                      <PlainHeader>Name</PlainHeader>
                      <PlainHeader>Status</PlainHeader>
                      <PlainHeader>Start date</PlainHeader>
                      <PlainHeader>Stop date</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {executions.length === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={loading}
                        loadingText="Loading executions…"
                        title="No executions"
                        text="Start an execution to see rows here."
                      />
                    ) : (
                      executions.map((ex) => {
                        const exName =
                          ex.name ??
                          ex.executionArn?.split(':').pop() ??
                          '—'
                        return (
                          <tr key={ex.executionArn ?? exName}>
                            <td>
                              <Mono>{exName}</Mono>
                            </td>
                            <td>
                              <StatusBadge
                                status={ex.status}
                                label={executionStatusLabel(ex.status)}
                              />
                            </td>
                            <td>{formatServiceDate(ex.startDate)}</td>
                            <td>{formatServiceDate(ex.stopDate)}</td>
                          </tr>
                        )
                      })
                    )}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}
        </div>
      </section>

      {showStart ? (
        <div className="modal-backdrop">
          <div className="modal" data-testid="sfn-start-modal">
            <h3>Start execution</h3>
            <Notices error={startError} />
            <label htmlFor="sfn-exec-name">Name — optional</label>
            <input
              id="sfn-exec-name"
              data-testid="sfn-exec-name"
              value={execName}
              onChange={(e) => setExecName(e.target.value)}
              placeholder="Leave blank to auto-generate"
              autoFocus
            />
            <label htmlFor="sfn-exec-input">Input — JSON</label>
            <textarea
              id="sfn-exec-input"
              data-testid="sfn-exec-input"
              value={execInput}
              onChange={(e) => setExecInput(e.target.value)}
              rows={8}
              spellCheck={false}
              style={{
                width: '100%',
                fontFamily: 'var(--aws-mono, ui-monospace, monospace)',
                fontSize: 12,
                lineHeight: 1.45,
              }}
            />
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setShowStart(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                data-testid="sfn-start-submit"
                disabled={busy || starting}
                onClick={() => void onStart()}
              >
                Start execution
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
