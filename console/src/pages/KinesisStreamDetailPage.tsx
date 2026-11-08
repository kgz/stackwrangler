import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { RefreshButton } from '../components/S3Ui'
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
  addStreamTags,
  DEFAULT_KMS_KEY,
  deleteDataStream,
  describeDataStream,
  listStreamShards,
  listStreamTags,
  putRecord,
  removeStreamTags,
  setRetentionPeriod,
  setStreamEncryption,
  waitStreamActive,
  type EncryptionChoice,
  type KinesisShardRow,
  type KinesisStreamDetail,
  type KinesisTag,
} from '../lib/kinesis'

type DetailTab = 'details' | 'shards' | 'tags'
type ModalKind = 'put' | 'retention' | 'encryption' | null

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['shards', 'Shards'],
  ['tags', 'Tags'],
]

export function KinesisStreamDetailPage() {
  const navigate = useNavigate()
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<KinesisStreamDetail | null>(null)
  const [shards, setShards] = useState<KinesisShardRow[]>([])
  const [tags, setTags] = useState<KinesisTag[]>([])
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [busy, setBusy] = useState(false)
  const [modal, setModal] = useState<ModalKind>(null)
  const [modalError, setModalError] = useState<string | null>(null)

  const [partitionKey, setPartitionKey] = useState('pk')
  const [recordData, setRecordData] = useState('')
  const [retentionHours, setRetentionHours] = useState('24')
  const [encryption, setEncryption] = useState<EncryptionChoice>('NONE')
  const [encryptionKeyId, setEncryptionKeyId] = useState(DEFAULT_KMS_KEY)
  const [newTagKey, setNewTagKey] = useState('')
  const [newTagValue, setNewTagValue] = useState('')

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
      try {
        setTags(await listStreamTags(name))
      } catch {
        setTags([])
      }
    } catch (err) {
      setDetail(null)
      setShards([])
      setTags([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  function openPut() {
    setPartitionKey('pk')
    setRecordData('')
    setModalError(null)
    setModal('put')
  }

  function openRetention() {
    setRetentionHours(String(detail?.retentionPeriodHours ?? 24))
    setModalError(null)
    setModal('retention')
  }

  function openEncryption() {
    const enc: EncryptionChoice =
      detail?.encryptionType === 'KMS' ? 'KMS' : 'NONE'
    setEncryption(enc)
    setEncryptionKeyId(detail?.keyId || DEFAULT_KMS_KEY)
    setModalError(null)
    setModal('encryption')
  }

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

  async function onPut() {
    if (!name) return
    setBusy(true)
    setModalError(null)
    try {
      const result = await putRecord(name, partitionKey, recordData)
      setModal(null)
      setToast(
        `Put record ${result.sequenceNumber || 'ok'}${
          result.shardId ? ` on ${result.shardId}` : ''
        }`,
      )
    } catch (err) {
      setModalError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onSaveRetention() {
    if (!name || !detail) return
    const hours = Math.floor(Number(retentionHours))
    setBusy(true)
    setModalError(null)
    try {
      await setRetentionPeriod(name, hours, detail.retentionPeriodHours)
      await waitStreamActive(name)
      setModal(null)
      setToast(`Retention set to ${hours} hours`)
      await refresh()
    } catch (err) {
      setModalError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onSaveEncryption() {
    if (!name || !detail) return
    setBusy(true)
    setModalError(null)
    try {
      await setStreamEncryption(
        name,
        encryption,
        encryptionKeyId,
        detail.keyId,
      )
      await waitStreamActive(name)
      setModal(null)
      setToast(
        encryption === 'KMS'
          ? `Encryption enabled (${encryptionKeyId.trim() || DEFAULT_KMS_KEY})`
          : 'Encryption disabled',
      )
      await refresh()
    } catch (err) {
      setModalError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onAddTag() {
    if (!name) return
    const key = newTagKey.trim()
    if (!key) {
      setError('Tag key is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await addStreamTags(name, { [key]: newTagValue })
      setNewTagKey('')
      setNewTagValue('')
      setToast(`Tag ${key} saved`)
      setTags(await listStreamTags(name))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onRemoveTag(key: string) {
    if (!name) return
    setBusy(true)
    setError(null)
    try {
      await removeStreamTags(name, [key])
      setToast(`Removed tag ${key}`)
      setTags(await listStreamTags(name))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const title = detail?.name ?? name
  const encryptionLabel =
    detail?.encryptionType === 'KMS'
      ? `KMS${detail.keyId ? ` (${detail.keyId})` : ''}`
      : (detail?.encryptionType ?? 'NONE')

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
            <button
              type="button"
              className="btn btn-primary"
              disabled={busy || !detail}
              onClick={openPut}
              data-testid="kinesis-put-records"
            >
              Put records
            </button>
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/kinesis">← Data streams</Link>
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
                    <span
                      key="retention"
                      style={{
                        display: 'inline-flex',
                        gap: 8,
                        alignItems: 'center',
                      }}
                    >
                      {detail.retentionPeriodHours != null
                        ? String(detail.retentionPeriodHours)
                        : '—'}
                      <button
                        type="button"
                        className="btn btn-normal"
                        disabled={busy}
                        onClick={openRetention}
                        data-testid="kinesis-edit-retention"
                      >
                        Edit
                      </button>
                    </span>,
                  ],
                  [
                    'Encryption',
                    <span
                      key="encryption"
                      style={{
                        display: 'inline-flex',
                        gap: 8,
                        alignItems: 'center',
                      }}
                    >
                      {encryptionLabel}
                      <button
                        type="button"
                        className="btn btn-normal"
                        disabled={busy}
                        onClick={openEncryption}
                        data-testid="kinesis-edit-encryption"
                      >
                        Edit
                      </button>
                    </span>,
                  ],
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

          {tab === 'tags' ? (
            <>
              <h2 className="aws-section-title">Tags</h2>
              <p className="aws-desc">
                LocalEmu <code>ListTagsForStream</code> /{' '}
                <code>AddTagsToStream</code> / <code>RemoveTagsFromStream</code>
                .
              </p>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="kinesis-tags-table">
                  <thead>
                    <tr>
                      <PlainHeader>Key</PlainHeader>
                      <PlainHeader>Value</PlainHeader>
                      <PlainHeader>Actions</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {tags.length === 0 ? (
                      <EmptyRow
                        colSpan={3}
                        loading={loading}
                        loadingText="Loading tags…"
                        title="No tags"
                        text="Add a tag below."
                      />
                    ) : (
                      tags.map((t) => (
                        <tr key={t.key}>
                          <td>
                            <Mono>{t.key}</Mono>
                          </td>
                          <td>{t.value || '—'}</td>
                          <td>
                            <button
                              type="button"
                              className="btn btn-normal"
                              disabled={busy}
                              onClick={() => void onRemoveTag(t.key)}
                              data-testid={`kinesis-remove-tag-${t.key}`}
                            >
                              Remove
                            </button>
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
              <div
                className="aws-toolbar"
                style={{ marginTop: 12, gap: 8, flexWrap: 'wrap' }}
              >
                <input
                  className="aws-input"
                  placeholder="Key"
                  value={newTagKey}
                  onChange={(e) => setNewTagKey(e.target.value)}
                  data-testid="kinesis-tag-key"
                  style={{ maxWidth: 180 }}
                  aria-label="New tag key"
                />
                <input
                  className="aws-input"
                  placeholder="Value"
                  value={newTagValue}
                  onChange={(e) => setNewTagValue(e.target.value)}
                  data-testid="kinesis-tag-value"
                  style={{ maxWidth: 220 }}
                  aria-label="New tag value"
                />
                <button
                  type="button"
                  className="btn btn-primary"
                  disabled={busy}
                  onClick={() => void onAddTag()}
                  data-testid="kinesis-tag-add"
                >
                  Add tag
                </button>
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

      {modal === 'put' ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            data-testid="kinesis-put-modal"
          >
            <h3>Put records</h3>
            <Notices error={modalError} />
            <label htmlFor="kinesis-partition-key">Partition key</label>
            <input
              id="kinesis-partition-key"
              className="aws-input"
              data-testid="kinesis-put-partition-key"
              value={partitionKey}
              onChange={(e) => setPartitionKey(e.target.value)}
              autoFocus
            />
            <label htmlFor="kinesis-record-data">Data</label>
            <textarea
              id="kinesis-record-data"
              className="aws-input"
              data-testid="kinesis-put-data"
              value={recordData}
              onChange={(e) => setRecordData(e.target.value)}
              rows={6}
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
                onClick={() => setModal(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onPut()}
                data-testid="kinesis-put-submit"
              >
                {busy ? 'Putting…' : 'Put record'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {modal === 'retention' ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            data-testid="kinesis-retention-modal"
          >
            <h3>Edit retention</h3>
            <Notices error={modalError} />
            <label htmlFor="kinesis-retention-hours">
              Retention period (hours)
            </label>
            <input
              id="kinesis-retention-hours"
              className="aws-input"
              type="number"
              min={24}
              max={8760}
              data-testid="kinesis-retention-hours"
              value={retentionHours}
              onChange={(e) => setRetentionHours(e.target.value)}
              style={{ maxWidth: 160 }}
            />
            <p className="aws-hint">24–8760 hours.</p>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setModal(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onSaveRetention()}
                data-testid="kinesis-retention-submit"
              >
                Save
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {modal === 'encryption' ? (
        <div className="modal-backdrop">
          <div
            className="modal"
            role="dialog"
            aria-modal="true"
            data-testid="kinesis-encryption-modal"
          >
            <h3>Edit encryption</h3>
            <Notices error={modalError} />
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="detail-encryption"
                    value="NONE"
                    checked={encryption === 'NONE'}
                    onChange={() => setEncryption('NONE')}
                    data-testid="kinesis-enc-none"
                  />
                  <span>None</span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="detail-encryption"
                    value="KMS"
                    checked={encryption === 'KMS'}
                    onChange={() => setEncryption('KMS')}
                    data-testid="kinesis-enc-kms"
                  />
                  <span>KMS</span>
                </label>
              </li>
            </ul>
            {encryption === 'KMS' ? (
              <>
                <label htmlFor="kinesis-enc-key">KMS key ID</label>
                <input
                  id="kinesis-enc-key"
                  className="aws-input"
                  data-testid="kinesis-enc-key"
                  value={encryptionKeyId}
                  onChange={(e) => setEncryptionKeyId(e.target.value)}
                  placeholder={DEFAULT_KMS_KEY}
                />
              </>
            ) : null}
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setModal(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onSaveEncryption()}
                data-testid="kinesis-encryption-submit"
              >
                Save
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
