import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { TO_IMPLEMENT } from '../components/S3Ui'
import { Notices } from '../components/ServiceUi'
import {
  createDataStream,
  type CapacityMode,
} from '../lib/kinesis'

export function KinesisCreatePage() {
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [capacityMode, setCapacityMode] =
    useState<CapacityMode>('PROVISIONED')
  const [shardCount, setShardCount] = useState('1')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onCreate() {
    const streamName = name.trim()
    if (!streamName) {
      setError('Data stream name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createDataStream({
        name: streamName,
        capacityMode,
        shardCount: Number(shardCount),
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
              <label className="aws-label">Data retention</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure retention…
              </button>
              <p className="aws-hint">LocalEmu default is 24 hours.</p>
            </div>
            <div className="aws-field">
              <label className="aws-label">Server-side encryption</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Configure encryption…
              </button>
            </div>
            <div className="aws-field">
              <label className="aws-label">Tags</label>
              <button
                type="button"
                className="btn btn-normal"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                Add tags…
              </button>
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
