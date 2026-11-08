import { useCallback, useEffect, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
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
import {
  describeRule,
  listRuleTargets,
  type EventBridgeRuleDetail,
  type EventBridgeTargetRow,
} from '../lib/events'

type DetailTab = 'details' | 'targets'

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['targets', 'Targets'],
]

export function EventBridgeRuleDetailPage() {
  const { name: rawName } = useParams()
  const [search] = useSearchParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const eventBusName = search.get('bus')?.trim() || 'default'
  const [detail, setDetail] = useState<EventBridgeRuleDetail | null>(null)
  const [targets, setTargets] = useState<EventBridgeTargetRow[]>([])
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const rule = await describeRule(name, eventBusName)
      setDetail(rule)
      try {
        setTargets(await listRuleTargets(name, eventBusName))
      } catch {
        setTargets([])
      }
    } catch (err) {
      setDetail(null)
      setTargets([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name, eventBusName])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const title = detail?.name ?? name

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
            <DeadButton>Delete</DeadButton>
            <DeadButton variant="primary">Edit</DeadButton>
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/events">← Rules</Link>
      </p>
      <Notices error={error} />

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
                <DeadButton>Remove</DeadButton>
                <div className="spacer" />
                <DeadButton variant="primary">Add target</DeadButton>
              </div>
              <table className="aws-table" data-testid="events-targets-table">
                <thead>
                  <tr>
                    <PlainHeader>Id</PlainHeader>
                    <PlainHeader>ARN</PlainHeader>
                  </tr>
                </thead>
                <tbody>
                  {targets.length === 0 ? (
                    <EmptyRow
                      colSpan={2}
                      loading={loading}
                      loadingText="Loading targets…"
                      title="No targets"
                      text="This rule has no targets."
                    />
                  ) : (
                    targets.map((t) => (
                      <tr key={t.id || t.arn}>
                        <td>{t.id || '—'}</td>
                        <td>
                          <Mono>{t.arn || '—'}</Mono>
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </>
          ) : null}
        </div>
      </section>
    </>
  )
}
