import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import {
  deleteObject,
  formatS3Error,
  getObjectBlob,
  listObjects,
  putObject,
  type S3Object,
} from '../lib/s3'

export function BucketObjectsPage() {
  const { name = '' } = useParams()
  const bucket = decodeURIComponent(name)
  const [objects, setObjects] = useState<S3Object[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const fileRef = useRef<HTMLInputElement>(null)

  const refresh = useCallback(async () => {
    if (!bucket) return
    setLoading(true)
    setError(null)
    try {
      setObjects(await listObjects(bucket))
    } catch (err) {
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

  return (
    <>
      <div className="crumbs">
        <Link to="/">Amazon S3</Link> &gt;{' '}
        <Link to="/">Buckets</Link> &gt; {bucket}
      </div>
      <h1 className="page-title">{bucket}</h1>

      {error ? <div className="error-banner">{error}</div> : null}

      <div className="panel">
        <div className="toolbar">
          <h3>Objects ({loading ? '…' : objects.length})</h3>
          <button type="button" className="btn" onClick={() => void refresh()}>
            Refresh
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
                    {o.LastModified
                      ? o.LastModified.toLocaleString()
                      : '—'}
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
    </>
  )
}
