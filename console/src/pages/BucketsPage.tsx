import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import {
  BucketTypeTabs,
  DeadButton,
  FilterHeader,
  InfoButton,
  RefreshButton,
  TableTools,
} from '../components/S3Ui'
import { config } from '../lib/config'
import { formatConsoleDate } from '../lib/format'
import {
  createBucket,
  emptyAndDeleteBucket,
  emptyBucket,
  formatS3Error,
  listBuckets,
  type S3Bucket,
} from '../lib/s3'

type ConfirmKind = 'empty' | 'delete' | null

export function BucketsPage() {
  const [buckets, setBuckets] = useState<S3Bucket[]>([])
  const [filter, setFilter] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [creating, setCreating] = useState(false)
  const [newName, setNewName] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const [confirm, setConfirm] = useState<ConfirmKind>(null)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const next = await listBuckets()
      setBuckets(next)
      setSelected((cur) =>
        cur && next.some((b) => b.Name === cur) ? cur : null,
      )
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

  async function onConfirmAction() {
    if (!confirm || !selected) return
    setBusy(true)
    setError(null)
    try {
      if (confirm === 'empty') {
        await emptyBucket(selected)
      } else {
        await emptyAndDeleteBucket(selected)
        setSelected(null)
      }
      setConfirm(null)
      await refresh()
    } catch (err) {
      setError(formatS3Error(err))
      setConfirm(null)
    } finally {
      setBusy(false)
    }
  }

  async function copyArn() {
    if (!selected) return
    await navigator.clipboard.writeText(`arn:aws:s3:::${selected}`)
  }

  function toggleRow(name: string) {
    setSelected((cur) => (cur === name ? null : name))
  }

  return (
    <>
      <div className="aws-main-split">
        <div className="aws-main-primary">
          <h1 className="aws-h1">Buckets</h1>
          <p className="aws-desc">
            This list is SeaweedFS (<code>{config.endpoint}</code>). Lambda /
            CFN / Transfer use LocalEmu S3 on <code>:4566</code> — separate
            store. See <code>docs/s3-backends.md</code>.
          </p>
          {error ? <div className="error-banner">{error}</div> : null}
          <section className="aws-card">
            <BucketTypeTabs active="gp" />
            <div className="aws-card-body">
              <h2 className="aws-section-title">
                General purpose buckets ({loading ? '…' : filtered.length}){' '}
                <InfoButton />
              </h2>
              <p className="aws-desc">
                Buckets are containers for data stored in S3.
              </p>
              <div className="aws-toolbar">
                <RefreshButton onClick={() => void refresh()} />
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={!selected}
                  title={selected ? undefined : 'Select a row'}
                  onClick={() => void copyArn()}
                >
                  Copy ARN
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={!selected || busy}
                  title={selected ? undefined : 'Select a row'}
                  onClick={() => setConfirm('empty')}
                >
                  Empty
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={!selected || busy}
                  title={selected ? undefined : 'Select a row'}
                  onClick={() => setConfirm('delete')}
                >
                  Delete
                </button>
                <DeadButton>Import</DeadButton>
                <div className="spacer" />
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() => setCreating(true)}
                >
                  Create bucket
                </button>
              </div>
              <TableTools
                placeholder="Find buckets by name"
                value={filter}
                onChange={setFilter}
              />
              <div className="aws-table-wrap">
                <table className="aws-table">
                  <thead>
                    <tr>
                      <th className="check" scope="col" aria-label="Select" />
                      <th scope="col">
                        <span className="th-inner">
                          Name <span aria-hidden="true">↑</span>
                        </span>
                      </th>
                      <FilterHeader>AWS Region</FilterHeader>
                      <FilterHeader>Creation date</FilterHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {loading ? (
                      <tr>
                        <td className="empty-cell" colSpan={4}>
                          Loading buckets…
                        </td>
                      </tr>
                    ) : filtered.length === 0 ? (
                      <tr>
                        <td className="empty-cell" colSpan={4}>
                          <strong>No buckets</strong>
                          You don&apos;t have any general purpose buckets.
                        </td>
                      </tr>
                    ) : (
                      filtered.map((b) => {
                        const name = b.Name ?? ''
                        const isSelected = selected === name
                        return (
                          <tr
                            key={name}
                            className={`selectable${isSelected ? ' selected' : ''}`}
                            onClick={() => toggleRow(name)}
                          >
                            <td
                              className="check"
                              onClick={(e) => e.stopPropagation()}
                            >
                              <input
                                type="radio"
                                name="selected-bucket"
                                checked={isSelected}
                                aria-label={`Select ${name}`}
                                onChange={() => toggleRow(name)}
                                onClick={() => {
                                  if (isSelected) setSelected(null)
                                }}
                              />
                            </td>
                            <td>
                              <ResourceLabel
                                ids={[name, `arn:aws:s3:::${name}`]}
                              >
                                <Link
                                  to={`/buckets/${encodeURIComponent(name)}`}
                                  onClick={(e) => e.stopPropagation()}
                                >
                                  {name}
                                </Link>
                              </ResourceLabel>
                            </td>
                            <td>{config.region}</td>
                            <td>
                              {b.CreationDate
                                ? formatConsoleDate(b.CreationDate)
                                : '—'}
                            </td>
                          </tr>
                        )
                      })
                    )}
                  </tbody>
                </table>
              </div>
            </div>
          </section>
        </div>
        <aside className="aws-side-widgets">
          <section className="aws-widget">
            <div className="aws-widget-head">
              <h3>Account snapshot</h3>
              <span className="aws-chip">Updated daily</span>
            </div>
            <p>
              Storage Lens provides visibility into storage usage and activity
              trends.
            </p>
            <Link className="btn btn-normal" to="/storage-lens">
              View dashboard
            </Link>
          </section>
          <section className="aws-widget">
            <div className="aws-widget-head">
              <h3>External access summary</h3>
              <span className="aws-chip">Updated daily</span>
            </div>
            <p>
              External access findings help you identify bucket permissions
              that allow public access or access from other AWS accounts.
            </p>
          </section>
        </aside>
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
              <button
                type="button"
                className="btn btn-normal"
                onClick={() => setCreating(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => void onCreate()}
              >
                Create bucket
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {confirm && selected ? (
        <div className="modal-backdrop">
          <div className="modal">
            <h3>
              {confirm === 'empty' ? 'Empty bucket?' : 'Delete bucket?'}
            </h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              {confirm === 'empty'
                ? `Delete all objects in ${selected}. The bucket itself stays.`
                : `Permanently delete ${selected} and all objects inside it.`}
            </p>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setConfirm(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onConfirmAction()}
              >
                {busy
                  ? 'Working…'
                  : confirm === 'empty'
                    ? 'Empty'
                    : 'Delete bucket'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
