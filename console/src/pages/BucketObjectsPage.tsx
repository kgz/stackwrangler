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

type ConfirmKind = 'empty' | 'delete' | null

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

export function BucketObjectsPage() {
  const { name = '' } = useParams()
  const bucket = decodeURIComponent(name)
  const navigate = useNavigate()
  const [objects, setObjects] = useState<S3Object[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [headOk, setHeadOk] = useState(false)
  const [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState<ConfirmKind>(null)
  const fileRef = useRef<HTMLInputElement>(null)

  const summary = useMemo(() => summarizeObjects(objects), [objects])

  const refresh = useCallback(async () => {
    if (!bucket) return
    setLoading(true)
    setError(null)
    try {
      await headBucket(bucket)
      setHeadOk(true)
      setObjects(await listObjects(bucket))
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

  async function onUpload(fileList: FileList | null) {
    if (!fileList || fileList.length === 0) return
    setError(null)
    try {
      for (const file of Array.from(fileList)) {
        await putObject(bucket, file.name, file)
      }
      await refresh()
    } catch (err) {
      setError(formatS3Error(err))
    }
  }

  async function onDownload(key: string) {
    setError(null)
    try {
      const blob = await getObjectBlob(bucket, key)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = key.split('/').pop() || key
      a.click()
      URL.revokeObjectURL(url)
    } catch (err) {
      setError(formatS3Error(err))
    }
  }

  async function onDelete(key: string) {
    setError(null)
    try {
      await deleteObject(bucket, key)
      await refresh()
    } catch (err) {
      setError(formatS3Error(err))
    }
  }

  async function onConfirmAction() {
    if (!confirm) return
    setBusy(true)
    setError(null)
    try {
      if (confirm === 'empty') {
        await emptyBucket(bucket)
        setConfirm(null)
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

  return (
    <>
      <div className="crumbs">
        <Link to="/">Amazon S3</Link> &gt; <Link to="/">Buckets</Link> &gt;{' '}
        {bucket}
      </div>
      <h1 className="page-title">{bucket}</h1>

      {error ? <div className="error-banner">{error}</div> : null}

      <div className="props-strip">
        <div>
          <span className="props-label">AWS Region</span>
          <span>{config.region}</span>
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

      <div className="panel">
        <div className="toolbar">
          <h3>Objects ({loading ? '…' : objects.length})</h3>
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
          </button>
          <button
            type="button"
            className="btn"
            disabled={loading || objects.length === 0 || busy}
            onClick={() => setConfirm('empty')}
          >
            Empty
          </button>
          <button
            type="button"
            className="btn"
            disabled={loading || busy}
            onClick={() => setConfirm('delete')}
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
        {objects.length === 0 && !loading ? (
          <div className="empty">
            <strong>No objects</strong>
            This bucket is empty. Upload a file to get started.
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th>Name</th>
                <th>Size</th>
                <th>Last modified</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {objects.map((o) => (
                <tr key={o.Key}>
                  <td>{o.Key}</td>
                  <td>{o.Size ?? 0}</td>
                  <td>
                    {o.LastModified ? o.LastModified.toLocaleString() : '—'}
                  </td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    <button
                      type="button"
                      className="btn-link"
                      onClick={() => void onDownload(o.Key ?? '')}
                    >
                      Download
                    </button>
                    {' · '}
                    <button
                      type="button"
                      className="btn-link"
                      onClick={() => void onDelete(o.Key ?? '')}
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {confirm ? (
        <div className="modal-backdrop">
          <div className="modal">
            <h3>
              {confirm === 'empty' ? 'Empty bucket?' : 'Delete bucket?'}
            </h3>
            <p style={{ color: 'var(--aws-text-muted)', marginTop: 0 }}>
              {confirm === 'empty'
                ? `Delete all objects in ${bucket}. The bucket itself stays.`
                : `Permanently delete ${bucket} and all objects inside it.`}
            </p>
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
