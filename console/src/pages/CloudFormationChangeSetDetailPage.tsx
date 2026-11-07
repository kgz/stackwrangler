import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import {
  Kv,
  Mono,
  Notices,
  PlainHeader,
  EmptyRow,
  StatusBadge,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  deleteChangeSet,
  describeChangeSet,
  executeChangeSet,
  type ChangeSetDetail,
} from '../lib/cfn'

export function CloudFormationChangeSetDetailPage() {
  const { name: rawName, changeSetName: rawCs } = useParams<{
    name: string
    changeSetName: string
  }>()
  const stackName = decodeURIComponent(rawName ?? '')
  const changeSetName = decodeURIComponent(rawCs ?? '')
  const navigate = useNavigate()
  const [detail, setDetail] = useState<ChangeSetDetail | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const d = await describeChangeSet({ stackName, changeSetName })
      setDetail(d)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [stackName, changeSetName])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onExecute() {
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      await executeChangeSet({ stackName, changeSetName })
      setToast(`Execute started for ${changeSetName}`)
      navigate(`/cloudformation/stacks/${encodeURIComponent(stackName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onDelete() {
    setBusy(true)
    setError(null)
    setToast(null)
    try {
      await deleteChangeSet({ stackName, changeSetName })
      navigate(`/cloudformation/stacks/${encodeURIComponent(stackName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const stackPath = `/cloudformation/stacks/${encodeURIComponent(stackName)}`
  const changes = detail?.changes ?? []
  const canExecute =
    (detail?.executionStatus ?? '').toUpperCase() === 'AVAILABLE'

  return (
    <>
      <div className="aws-toolbar">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1" style={{ margin: 0 }}>
            {changeSetName}
          </h1>
          {detail ? (
            <div className="aws-subtitle-row">
              <StatusBadge status={detail.status} />
              <span>Execution status: {detail.executionStatus ?? '—'}</span>
              <span>
                Stack: <Link to={stackPath}>{stackName}</Link>
              </span>
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
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy || !canExecute}
          title={canExecute ? undefined : 'Change set is not executable'}
          onClick={() => void onExecute()}
        >
          Execute change set
        </button>
      </div>

      <Notices error={error} toast={toast} />

      <section className="aws-card">
        <div className="aws-card-body">
          {loading ? (
            <p className="aws-desc">Loading…</p>
          ) : (
            <>
              <h2 className="aws-section-title">Overview</h2>
              <Kv
                rows={[
                  [
                    'Change set ID',
                    <Mono key="id">{detail?.changeSetId ?? '—'}</Mono>,
                  ],
                  [
                    'Stack',
                    <Link key="stack" to={stackPath}>
                      {stackName}
                    </Link>,
                  ],
                  ['Description', detail?.description ?? '—'],
                  [
                    'Creation time',
                    formatServiceDate(detail?.creationTime),
                  ],
                  [
                    'Status',
                    <StatusBadge key="st" status={detail?.status} />,
                  ],
                  ['Execution status', detail?.executionStatus ?? '—'],
                  ['Status reason', detail?.statusReason ?? '—'],
                ]}
              />

              <h2 className="aws-section-title" style={{ marginTop: 20 }}>
                Changes
              </h2>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="changeset-changes">
                  <thead>
                    <tr>
                      <PlainHeader>Action</PlainHeader>
                      <PlainHeader>Logical ID</PlainHeader>
                      <PlainHeader>Resource type</PlainHeader>
                      <PlainHeader>Replacement</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {changes.length === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={false}
                        loadingText=""
                        title="No changes"
                      />
                    ) : (
                      changes.map((c, i) => {
                        const res = c.ResourceChange
                        return (
                          <tr
                            key={`${res?.LogicalResourceId ?? 'chg'}-${i}`}
                          >
                            <td>{res?.Action ?? c.Type ?? '—'}</td>
                            <td>{res?.LogicalResourceId ?? '—'}</td>
                            <td>{res?.ResourceType ?? '—'}</td>
                            <td>{res?.Replacement ?? '—'}</td>
                          </tr>
                        )
                      })
                    )}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </div>
      </section>
    </>
  )
}
