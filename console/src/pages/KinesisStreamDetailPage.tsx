import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
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
  deleteDataStream,
  describeDataStream,
  listStreamShards,
  type KinesisShardRow,
  type KinesisStreamDetail,
} from '../lib/kinesis'

type DetailTab = 'details' | 'shards'

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['shards', 'Shards'],
]

export function KinesisStreamDetailPage() {
  const navigate = useNavigate()
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<KinesisStreamDetail | null>(null)
  const [shards, setShards] = useState<KinesisShardRow[]>([])
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const stream = await describeDataStream(name)
      setDetail(stream)
      try {
        setShards(await listStreamShards(name))
      } catch {
        setShards([])
      }
    } catch (err) {
      setDetail(null)
      setShards([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  async function onDelete() {
    if (!name) return
    setBusy(true)
    setError(null)
    try {
      await deleteDataStream(name)
      navigate('/kinesis')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setConfirmDelete(false)
    } finally {
      setBusy(false)
    }
  }

  const title = detail?.name ?? name

  return (
    <>
      <DetailHeader
        title={title}
        subtitle={
          <>
            <span>{detail?.status ?? '—'}</span>
            <span>{detail?.capacityMode ?? '—'}</span>
            <span>Created {formatServiceDate(detail?.createdOn)}</span>
          </>
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled={busy || !detail}
              onClick={() => setConfirmDelete(true)}
              data-testid="kinesis-detail-delete"
            >
              Delete
            </button>
            <DeadButton variant="primary">Put records</DeadButton>
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/kinesis">← Data streams</Link>
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
              data-testid={`kinesis-tab-${id}`}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="aws-card-body">
          {loading && !detail ? <p className="aws-desc">Loading…</p> : null}

          {tab === 'details' && detail ? (
            <>
              <h2 className="aws-section-title">Data stream details</h2>
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
                  ['Capacity mode', detail.capacityMode],
                  [
                    'Open shard count',
                    detail.openShardCount != null
                      ? String(detail.openShardCount)
                      : '—',
                  ],
                  [
                    'Retention period (hours)',
                    detail.retentionPeriodHours != null
                      ? String(detail.retentionPeriodHours)
                      : '—',
                  ],
                  ['Encryption', detail.encryptionType],
                  ['Created', formatServiceDate(detail.createdOn)],
                ]}
              />
            </>
          ) : null}

          {tab === 'shards' ? (
            <>
              <h2 className="aws-section-title">Shards summary</h2>
              <p className="aws-desc">
                Open shards from LocalEmu <code>ListShards</code>.
              </p>
              <div className="aws-table-wrap">
                <table
                  className="aws-table"
                  data-testid="kinesis-shards-table"
                >
                  <thead>
                    <tr>
                      <PlainHeader>Shard ID</PlainHeader>
                      <PlainHeader>Starting hash key</PlainHeader>
                      <PlainHeader>Ending hash key</PlainHeader>
                      <PlainHeader>Starting sequence</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {shards.length === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={loading}
                        loadingText="Loading shards…"
                        title="No shards"
                        text="Shards appear once the stream is ACTIVE."
                      />
                    ) : (
                      shards.map((s) => (
                        <tr key={s.shardId}>
                          <td>
                            <Mono>{s.shardId}</Mono>
                          </td>
                          <td>
                            <Mono>{s.startingHashKey}</Mono>
                          </td>
                          <td>
                            <Mono>{s.endingHashKey}</Mono>
                          </td>
                          <td>
                            <Mono>{s.startingSequenceNumber}</Mono>
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}
        </div>
      </section>

      {confirmDelete ? (
        <div className="modal-backdrop">
          <div className="modal" role="dialog" aria-modal="true">
            <h3>Delete data stream?</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Permanently delete <strong>{title}</strong>. In-flight records are
              discarded.
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
                data-testid="kinesis-confirm-delete"
              >
                {busy ? 'Deleting…' : 'Delete data stream'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
