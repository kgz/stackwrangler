import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Notices } from '../components/ServiceUi'
import {
  createDataStream,
  DEFAULT_KMS_KEY,
  DEFAULT_RETENTION_HOURS,
  type CapacityMode,
  type EncryptionChoice,
  type KinesisTag,
} from '../lib/kinesis'

type TagDraft = KinesisTag & { id: string }

let tagSeq = 0
function newTagDraft(key = '', value = ''): TagDraft {
  tagSeq += 1
  return { id: `tag-${tagSeq}`, key, value }
}

export function KinesisCreatePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [capacityMode, setCapacityMode] =
    useState<CapacityMode>('PROVISIONED')
  const [shardCount, setShardCount] = useState('1')
  const [retentionHours, setRetentionHours] = useState(
    String(DEFAULT_RETENTION_HOURS),
  )
  const [encryption, setEncryption] = useState<EncryptionChoice>('NONE')
  const [encryptionKeyId, setEncryptionKeyId] = useState(DEFAULT_KMS_KEY)
  const [tags, setTags] = useState<TagDraft[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const streamName = name.trim()
    if (!streamName) {
      setError('Data stream name is required')
      return
    }
    const retention = Math.floor(Number(retentionHours))
    if (!Number.isFinite(retention) || retention < 24 || retention > 8760) {
      setError('Retention must be between 24 and 8760 hours')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createDataStream({
        name: streamName,
        capacityMode,
        shardCount: Number(shardCount),
        retentionPeriodHours: retention,
        encryption,
        encryptionKeyId:
          encryption === 'KMS' ? encryptionKeyId : undefined,
        tags: tags
          .map((t) => ({ key: t.key.trim(), value: t.value }))
          .filter((t) => t.key),
      })
      navigate(`/kinesis/streams/${encodeURIComponent(streamName)}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <h1 className="aws-h1">Create data stream</h1>
      <p className="aws-desc">
        Create a Kinesis data stream with provisioned shards or on-demand
        capacity. LocalEmu accepts both modes via <code>CreateStream</code>.
        Retention, encryption, and tags apply after the stream is ACTIVE.
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-card-body aws-form-stack">
          <div className="aws-form-section">
            <h2 className="aws-section-title">Stream details</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="stream-name">
                Data stream name <span className="req">*</span>
              </label>
              <input
                className="aws-input"
                id="stream-name"
                name="name"
                type="text"
                autoComplete="off"
                placeholder="my-data-stream"
                value={name}
                onChange={(e) => setName(e.target.value)}
                data-testid="kinesis-create-name"
              />
              <p className="aws-hint">
                1–128 characters. Letters, numbers, underscores, hyphens, and
                periods.
              </p>
            </div>
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Capacity mode</h2>
            <ul className="aws-radio-list">
              <li>
                <label>
                  <input
                    type="radio"
                    name="capacityMode"
                    value="PROVISIONED"
                    checked={capacityMode === 'PROVISIONED'}
                    onChange={() => setCapacityMode('PROVISIONED')}
                    data-testid="kinesis-mode-provisioned"
                  />
                  <span>
                    <strong>Provisioned</strong>
                    <span className="sub">
                      You choose the number of shards. Best for predictable
                      throughput.
                    </span>
                  </span>
                </label>
              </li>
              <li>
                <label>
                  <input
                    type="radio"
                    name="capacityMode"
                    value="ON_DEMAND"
                    checked={capacityMode === 'ON_DEMAND'}
                    onChange={() => setCapacityMode('ON_DEMAND')}
                    data-testid="kinesis-mode-on-demand"
                  />
                  <span>
                    <strong>On-demand</strong>
                    <span className="sub">
                      Capacity scales automatically. Shard count is managed for
                      you.
                    </span>
                  </span>
                </label>
              </li>
            </ul>
            {capacityMode === 'PROVISIONED' ? (
              <div className="aws-field" style={{ marginTop: 12 }}>
                <label className="aws-label" htmlFor="shard-count">
                  Number of open shards <span className="req">*</span>
                </label>
                <input
                  className="aws-input"
                  id="shard-count"
                  name="shardCount"
                  type="number"
                  min={1}
                  max={10000}
                  value={shardCount}
                  onChange={(e) => setShardCount(e.target.value)}
                  data-testid="kinesis-create-shard-count"
                  style={{ maxWidth: 160 }}
                />
                <p className="aws-hint">
                  Required for provisioned mode. Each shard provides 1 MiB/s or
                  1000 records/s ingress.
                </p>
              </div>
            ) : null}
          </div>

          <div className="aws-form-section">
            <h2 className="aws-section-title">Additional settings</h2>
            <div className="aws-field">
              <label className="aws-label" htmlFor="retention-hours">
                Data retention (hours)
              </label>
              <input
                className="aws-input"
                id="retention-hours"
                type="number"
                min={24}
                max={8760}
                value={retentionHours}
                onChange={(e) => setRetentionHours(e.target.value)}
                data-testid="kinesis-create-retention"
                style={{ maxWidth: 160 }}
              />
              <p className="aws-hint">
                LocalEmu default is {DEFAULT_RETENTION_HOURS} hours. Values above
                default use IncreaseStreamRetentionPeriod after create.
              </p>
            </div>
            <div className="aws-field">
              <label className="aws-label">Server-side encryption</label>
              <ul className="aws-radio-list">
                <li>
                  <label>
                    <input
                      type="radio"
                      name="encryption"
                      value="NONE"
                      checked={encryption === 'NONE'}
                      onChange={() => setEncryption('NONE')}
                      data-testid="kinesis-create-enc-none"
                    />
                    <span>
                      <strong>None</strong>
                      <span className="sub">No server-side encryption.</span>
                    </span>
                  </label>
                </li>
                <li>
                  <label>
                    <input
                      type="radio"
                      name="encryption"
                      value="KMS"
                      checked={encryption === 'KMS'}
                      onChange={() => setEncryption('KMS')}
                      data-testid="kinesis-create-enc-kms"
                    />
                    <span>
                      <strong>KMS</strong>
                      <span className="sub">
                        StartStreamEncryption after the stream is ACTIVE.
                      </span>
                    </span>
                  </label>
                </li>
              </ul>
              {encryption === 'KMS' ? (
                <div className="aws-field" style={{ marginTop: 12 }}>
                  <label className="aws-label" htmlFor="kms-key-id">
                    KMS key ID
                  </label>
                  <input
                    className="aws-input"
                    id="kms-key-id"
                    type="text"
                    value={encryptionKeyId}
                    onChange={(e) => setEncryptionKeyId(e.target.value)}
                    data-testid="kinesis-create-kms-key"
                    placeholder={DEFAULT_KMS_KEY}
                  />
                </div>
              ) : null}
            </div>
            <div className="aws-field">
              <label className="aws-label">Tags</label>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="kinesis-create-tags">
                  <thead>
                    <tr>
                      <th scope="col">Key</th>
                      <th scope="col">Value</th>
                      <th scope="col" />
                    </tr>
                  </thead>
                  <tbody>
                    {tags.length === 0 ? (
                      <tr>
                        <td colSpan={3}>
                          <p className="aws-desc" style={{ margin: 0 }}>
                            No tags yet.
                          </p>
                        </td>
                      </tr>
                    ) : (
                      tags.map((t, idx) => (
                        <tr key={t.id}>
                          <td>
                            <input
                              className="aws-input"
                              value={t.key}
                              onChange={(e) =>
                                setTags((prev) =>
                                  prev.map((row) =>
                                    row.id === t.id
                                      ? { ...row, key: e.target.value }
                                      : row,
                                  ),
                                )
                              }
                              data-testid={`kinesis-create-tag-key-${idx}`}
                              aria-label="Tag key"
                            />
                          </td>
                          <td>
                            <input
                              className="aws-input"
                              value={t.value}
                              onChange={(e) =>
                                setTags((prev) =>
                                  prev.map((row) =>
                                    row.id === t.id
                                      ? { ...row, value: e.target.value }
                                      : row,
                                  ),
                                )
                              }
                              data-testid={`kinesis-create-tag-value-${idx}`}
                              aria-label="Tag value"
                            />
                          </td>
                          <td>
                            <button
                              type="button"
                              className="btn btn-normal"
                              onClick={() =>
                                setTags((prev) =>
                                  prev.filter((row) => row.id !== t.id),
                                )
                              }
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
              <button
                type="button"
                className="btn btn-normal"
                style={{ marginTop: 8 }}
                onClick={() => setTags((prev) => [...prev, newTagDraft()])}
                data-testid="kinesis-create-add-tag"
              >
                Add tag
              </button>
              <p className="aws-hint">
                Applied with AddTagsToStream after create (LocalEmu CreateStream
                tags are not persisted).
              </p>
            </div>
          </div>
        </div>
      </section>

      <div className="aws-toolbar" style={{ marginTop: 16 }}>
        <Link className="btn btn-normal" to="/kinesis">
          Cancel
        </Link>
        <div className="spacer" />
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void onCreate()}
          data-testid="kinesis-create-submit"
        >
          {busy ? 'Creating…' : 'Create data stream'}
        </button>
      </div>
    </>
  )
}
