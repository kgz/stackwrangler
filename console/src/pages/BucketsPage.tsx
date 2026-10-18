import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { config } from '../lib/config'
import {
  createBucket,
  formatS3Error,
  listBuckets,
  type S3Bucket,
} from '../lib/s3'

export function BucketsPage() {
  const [buckets, setBuckets] = useState<S3Bucket[]>([])
  const [filter, setFilter] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [creating, setCreating] = useState(false)
  const [newName, setNewName] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setBuckets(await listBuckets())
    } catch (err) {
      setError(formatS3Error(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return buckets
    return buckets.filter((b) => (b.Name ?? '').toLowerCase().includes(q))
  }, [buckets, filter])

  async function onCreate() {
    const name = newName.trim()
    if (!name) return
    setError(null)
    try {
      await createBucket(name)
      setCreating(false)
      setNewName('')
      await refresh()
    } catch (err) {
      setError(formatS3Error(err))
    }
  }

  return (
    <>
      <div className="crumbs">
        <Link to="/">Amazon S3</Link> &gt; Buckets
      </div>
      <h1 className="page-title">Buckets</h1>
      <div className="tabs">
        <button type="button" className="active">
          General purpose buckets
        </button>
        <button type="button" disabled>
          Directory buckets
        </button>
      </div>

      {error ? <div className="error-banner">{error}</div> : null}

      <div className="panel">
        <div className="toolbar">
          <h3>
            General purpose buckets ({loading ? '…' : filtered.length})
          </h3>
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button type="button" className="btn" disabled>
            Empty
          </button>
          <button type="button" className="btn" disabled>
            Delete
          </button>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => setCreating(true)}
          >
            Create bucket
          </button>
        </div>
        <div className="filters">
          <input
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            placeholder="Find buckets by name"
          />
        </div>
        {filtered.length === 0 && !loading ? (
          <div className="empty">
            <strong>No buckets</strong>
            You don&apos;t have any general purpose buckets in the{' '}
            {config.regionLabel} {config.region} Region.
            <div style={{ marginTop: 16 }}>
              <button
                type="button"
                className="btn-link"
                onClick={() => setCreating(true)}
              >
                Create bucket
              </button>
            </div>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th>Name</th>
                <th>AWS Region</th>
                <th>Creation date</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((b) => (
                <tr key={b.Name}>
                  <td>
                    <Link to={`/buckets/${encodeURIComponent(b.Name ?? '')}`}>
                      {b.Name}
                    </Link>
                  </td>
                  <td>{config.region}</td>
                  <td>
                    {b.CreationDate
                      ? b.CreationDate.toLocaleString()
                      : '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {creating ? (
        <div className="modal-backdrop">
          <div className="modal">
            <h3>Create bucket</h3>
            <label htmlFor="bucket-name">Bucket name</label>
            <input
              id="bucket-name"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="my-bucket-name"
              autoFocus
              onKeyDown={(e) => {
                if (e.key === 'Enter') void onCreate()
              }}
            />
            <div className="modal-actions">
              <button type="button" className="btn" onClick={() => setCreating(false)}>
                Cancel
              </button>
              <button type="button" className="btn btn-primary" onClick={() => void onCreate()}>
                Create bucket
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
