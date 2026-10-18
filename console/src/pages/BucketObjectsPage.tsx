import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { config } from '../lib/config'
import {
  deleteObject,
  emptyAndDeleteBucket,
  emptyBucket,
  formatS3Error,
  getObjectBlob,
  headBucket,
  listObjects,
  putObject,
  summarizeObjects,
  type S3Object,
} from '../lib/s3'

type ConfirmKind = 'empty-bucket' | 'delete-bucket' | 'delete-objects' | null

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

function objectType(key: string): string {
  const i = key.lastIndexOf('.')
  if (i < 0 || i === key.length - 1) return '—'
  return key.slice(i + 1).toLowerCase()
}

export function BucketObjectsPage() {
  const { name = '' } = useParams()
  const bucket = decodeURIComponent(name)
  const navigate = useNavigate()
  const [objects, setObjects] = useState<S3Object[]>([])
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [headOk, setHeadOk] = useState(false)
  const [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState<ConfirmKind>(null)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [prefix, setPrefix] = useState('')
  const [tab, setTab] = useState<'objects' | 'properties'>('objects')
  const fileRef = useRef<HTMLInputElement>(null)

  const summary = useMemo(() => summarizeObjects(objects), [objects])

  const filtered = useMemo(() => {
    const q = prefix.trim()
    if (!q) return objects
    return objects.filter((o) => (o.Key ?? '').startsWith(q))
  }, [objects, prefix])

  const selectedKeys = useMemo(() => [...selected], [selected])

  const refresh = useCallback(async () => {
    if (!bucket) return
    setLoading(true)
    setError(null)
    try {
      await headBucket(bucket)
      setHeadOk(true)
      const next = await listObjects(bucket)
      setObjects(next)
      setSelected((cur) => {
        const keys = new Set(next.map((o) => o.Key).filter(Boolean))
        const keep = new Set<string>()
        for (const k of cur) {
          if (keys.has(k)) keep.add(k)
        }
        return keep
      })
    } catch (err) {
      setHeadOk(false)
      setError(formatS3Error(err))
    } finally {
      setLoading(false)
    }
  }, [bucket])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!toast) return
    const t = window.setTimeout(() => setToast(null), 4000)
    return () => window.clearTimeout(t)
  }, [toast])

  function toggleKey(key: string) {
    setSelected((cur) => {
      const next = new Set(cur)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  function toggleAllVisible() {
    const keys = filtered.map((o) => o.Key).filter((k): k is string => !!k)
    setSelected((cur) => {
      const allOn = keys.length > 0 && keys.every((k) => cur.has(k))
      if (allOn) return new Set()
      return new Set(keys)
    })
  }

  async function onUpload(fileList: FileList | null) {
    if (!fileList || fileList.length === 0) return
    setError(null)
    try {
      for (const file of Array.from(fileList)) {
        await putObject(bucket, file.name, file)
      }
      setToast(`Uploaded ${fileList.length} object(s).`)
      await refresh()
    } catch (err) {
      setError(formatS3Error(err))
    }
  }

  async function onDownloadSelected() {
    setError(null)
    try {
      for (const key of selectedKeys) {
        const blob = await getObjectBlob(bucket, key)
        const url = URL.createObjectURL(blob)
        const a = document.createElement('a')
        a.href = url
        a.download = key.split('/').pop() || key
        a.click()
        URL.revokeObjectURL(url)
      }
    } catch (err) {
      setError(formatS3Error(err))
    }
  }

  async function copyS3Uri() {
    if (selectedKeys.length !== 1) return
    const uri = `s3://${bucket}/${selectedKeys[0]}`
    await navigator.clipboard.writeText(uri)
    setToast('Copied S3 URI')
  }

  async function onConfirmAction() {
    if (!confirm) return
    setBusy(true)
    setError(null)
    try {
      if (confirm === 'delete-objects') {
        const keys = [...selectedKeys]
        for (const key of keys) {
          await deleteObject(bucket, key)
        }
        setSelected(new Set())
        setConfirm(null)
        setToast(
          keys.length === 1
            ? `Successfully deleted object ${keys[0]}.`
            : `Successfully deleted ${keys.length} objects.`,
        )
        await refresh()
      } else if (confirm === 'empty-bucket') {
        await emptyBucket(bucket)
        setSelected(new Set())
        setConfirm(null)
        setToast(`Emptied bucket ${bucket}.`)
        await refresh()
      } else {
        await emptyAndDeleteBucket(bucket)
        setConfirm(null)
        navigate('/')
      }
    } catch (err) {
      setError(formatS3Error(err))
      setConfirm(null)
    } finally {
      setBusy(false)
    }
  }

  const allVisibleSelected =
    filtered.length > 0 &&
    filtered.every((o) => o.Key && selected.has(o.Key))

  return (
    <>
      <div className="crumbs">
        <Link to="/">Amazon S3</Link> &gt; <Link to="/">Buckets</Link> &gt;{' '}
        {bucket}
      </div>
      <h1 className="page-title">{bucket}</h1>

      <div className="tabs">
        <button
          type="button"
          className={tab === 'objects' ? 'active' : undefined}
          onClick={() => setTab('objects')}
        >
          Objects
        </button>
        <button
          type="button"
          className={tab === 'properties' ? 'active' : undefined}
          onClick={() => setTab('properties')}
        >
          Properties
        </button>
        <button type="button" disabled>
          Permissions
        </button>
        <button type="button" disabled>
          Metrics
        </button>
        <button type="button" disabled>
          Management
        </button>
        <button type="button" disabled>
          Access Points
        </button>
      </div>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? <div className="toast-banner">{toast}</div> : null}

      {tab === 'properties' ? (
        <div className="panel">
          <div className="toolbar">
            <h3>Properties</h3>
          </div>
          <div className="props-strip" style={{ border: 0, padding: 16 }}>
            <div>
              <span className="props-label">AWS Region</span>
              <span>{config.region}</span>
            </div>
            <div>
              <span className="props-label">Amazon Resource Name (ARN)</span>
              <span>arn:aws:s3:::{bucket}</span>
            </div>
            <div>
              <span className="props-label">Objects</span>
              <span>{loading ? '…' : summary.count}</span>
            </div>
            <div>
              <span className="props-label">Total size</span>
              <span>{loading ? '…' : formatBytes(summary.totalBytes)}</span>
            </div>
            <div>
              <span className="props-label">HeadBucket</span>
              <span>{headOk ? 'OK' : '—'}</span>
            </div>
          </div>
          <div className="toolbar" style={{ borderTop: '1px solid var(--aws-border)' }}>
            <button
              type="button"
              className="btn"
              disabled={loading || objects.length === 0 || busy}
              onClick={() => setConfirm('empty-bucket')}
            >
              Empty bucket
            </button>
            <button
              type="button"
              className="btn"
              disabled={loading || busy}
              onClick={() => setConfirm('delete-bucket')}
            >
              Delete bucket
            </button>
          </div>
        </div>
      ) : (
        <div className="panel">
          <div className="toolbar toolbar-stack">
            <div>
              <h3>
                Objects ({loading ? '…' : `${filtered.length}/${objects.length}`})
              </h3>
              <p className="toolbar-help">
                Objects are the fundamental entities stored in Amazon S3. For
                others to access your objects, you&apos;ll need to explicitly
                grant them permissions.
              </p>
            </div>
            <div className="toolbar-actions">
              <button
                type="button"
                className="btn"
                onClick={() => void refresh()}
              >
                Refresh
              </button>
              <button
                type="button"
                className="btn"
                disabled={selectedKeys.length !== 1}
                onClick={() => void copyS3Uri()}
              >
                Copy S3 URI
              </button>
              <button
                type="button"
                className="btn"
                disabled={selectedKeys.length === 0 || busy}
                onClick={() => void onDownloadSelected()}
              >
                Download
              </button>
              <button
                type="button"
                className="btn"
                disabled={selectedKeys.length === 0 || busy}
                onClick={() => setConfirm('delete-objects')}
              >
                Delete
              </button>
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => fileRef.current?.click()}
              >
                Upload
              </button>
              <input
                ref={fileRef}
                type="file"
                multiple
                hidden
                onChange={(e) => {
                  void onUpload(e.target.files)
                  e.target.value = ''
                }}
              />
            </div>
          </div>
          <div className="filters">
            <input
              value={prefix}
              onChange={(e) => setPrefix(e.target.value)}
              placeholder="Find objects by prefix"
            />
          </div>
          {filtered.length === 0 && !loading ? (
            <div className="empty">
              <strong>No objects</strong>
              This bucket is empty. Upload a file to get started.
            </div>
          ) : (
            <table className="data">
              <thead>
                <tr>
                  <th className="col-check">
                    <input
                      type="checkbox"
                      checked={allVisibleSelected}
                      aria-label="Select all objects"
                      onChange={toggleAllVisible}
                    />
                  </th>
                  <th>Name</th>
                  <th>Type</th>
                  <th>Last modified</th>
                  <th>Size</th>
                  <th>Storage class</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((o) => {
                  const key = o.Key ?? ''
                  const isSelected = selected.has(key)
                  return (
                    <tr
                      key={key}
                      className={isSelected ? 'row-selected' : undefined}
                      onClick={() => toggleKey(key)}
                    >
                      <td
                        className="col-check"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <input
                          type="checkbox"
                          checked={isSelected}
                          aria-label={`Select ${key}`}
                          onChange={() => toggleKey(key)}
                        />
                      </td>
                      <td>{key}</td>
                      <td>{objectType(key)}</td>
                      <td>
                        {o.LastModified
                          ? o.LastModified.toLocaleString()
                          : '—'}
                      </td>
                      <td>{formatBytes(o.Size ?? 0)}</td>
                      <td>STANDARD</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
        </div>
      )}

      {confirm ? (
        <div className="modal-backdrop">
          <div className="modal">
            <h3>
              {confirm === 'delete-objects'
                ? `Delete objects (${selectedKeys.length})?`
                : confirm === 'empty-bucket'
                  ? 'Empty bucket?'
                  : 'Delete bucket?'}
            </h3>
            <p style={{ color: 'var(--aws-text-muted)', marginTop: 0 }}>
              {confirm === 'delete-objects'
                ? 'This action cannot be undone. Specifying permanent delete permanently deletes objects.'
                : confirm === 'empty-bucket'
                  ? `Delete all objects in ${bucket}. The bucket itself stays.`
                  : `Permanently delete ${bucket} and all objects inside it.`}
            </p>
            {confirm === 'delete-objects' ? (
              <ul className="confirm-list">
                {selectedKeys.map((k) => (
                  <li key={k}>{k}</li>
                ))}
              </ul>
            ) : null}
            <div className="modal-actions">
              <button
                type="button"
                className="btn"
                disabled={busy}
                onClick={() => setConfirm(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-danger"
                disabled={busy}
                onClick={() => void onConfirmAction()}
              >
                {busy
                  ? 'Working…'
                  : confirm === 'delete-objects'
                    ? 'Delete objects'
                    : confirm === 'empty-bucket'
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
