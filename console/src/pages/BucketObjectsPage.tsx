import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { ObjectPreview } from '../components/ObjectPreview'
import { ResourceLabel } from '../components/ResourceLabel'
import {
  DeadButton,
  InfoButton,
  RefreshButton,
  TO_IMPLEMENT,
  TableTools,
} from '../components/S3Ui'
import { config } from '../lib/config'
import { formatBytes, formatConsoleDate } from '../lib/format'
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
  const [previewKey, setPreviewKey] = useState<string | null>(null)
  const [actionsOpen, setActionsOpen] = useState(false)
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
    if (!actionsOpen) return
    function close(e: MouseEvent) {
      if (!(e.target instanceof Element) || !e.target.closest('.aws-pop')) {
        setActionsOpen(false)
      }
    }
    document.addEventListener('click', close)
    return () => document.removeEventListener('click', close)
  }, [actionsOpen])

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

  async function downloadKeys(keys: string[]) {
    setError(null)
    try {
      for (const key of keys) {
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

  async function onDownloadSelected() {
    await downloadKeys(selectedKeys)
  }

  async function copyS3Uri() {
    if (selectedKeys.length !== 1) return
    const uri = `s3://${bucket}/${selectedKeys[0]}`
    await navigator.clipboard.writeText(uri)
    setToast('Copied S3 URI')
  }

  const dead = (label: string) => (
    <button type="button" disabled aria-disabled="true" title={TO_IMPLEMENT}>
      {label}
    </button>
  )

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
      <h1 className="aws-h1">
        <ResourceLabel ids={[bucket, `arn:aws:s3:::${bucket}`]} detail>
          {bucket}
        </ResourceLabel>{' '}
        <InfoButton />
      </h1>

      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? <div className="toast-banner">{toast}</div> : null}

      <section className="aws-card">
        <div className="aws-tabs">
          <button
            type="button"
            aria-current={tab === 'objects' ? 'page' : undefined}
            className={`aws-tab${tab === 'objects' ? ' active' : ''}`}
            onClick={() => setTab('objects')}
          >
            Objects
          </button>
          <button
            type="button"
            aria-current={tab === 'properties' ? 'page' : undefined}
            className={`aws-tab${tab === 'properties' ? ' active' : ''}`}
            onClick={() => setTab('properties')}
          >
            Properties
          </button>
          {['Permissions', 'Metrics', 'Management', 'Access Points'].map(
            (label) => (
              <button
                key={label}
                type="button"
                className="aws-tab"
                disabled
                aria-disabled="true"
                title={TO_IMPLEMENT}
              >
                {label}
              </button>
            ),
          )}
        </div>
        <div className="aws-card-body">
          {tab === 'properties' ? (
            <>
              <h2 className="aws-section-title">Bucket overview</h2>
              <dl className="aws-kv">
                <div>
                  <dt>AWS Region</dt>
                  <dd>{config.region}</dd>
                </div>
                <div>
                  <dt>Amazon Resource Name (ARN)</dt>
                  <dd className="aws-mono">arn:aws:s3:::{bucket}</dd>
                </div>
                <div>
                  <dt>Objects</dt>
                  <dd>{loading ? '…' : summary.count}</dd>
                </div>
                <div>
                  <dt>Total size</dt>
                  <dd>{loading ? '…' : formatBytes(summary.totalBytes)}</dd>
                </div>
                <div>
                  <dt>HeadBucket</dt>
                  <dd>{headOk ? 'OK' : '—'}</dd>
                </div>
              </dl>
              <div className="aws-toolbar" style={{ marginTop: 16 }}>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={loading || objects.length === 0 || busy}
                  onClick={() => setConfirm('empty-bucket')}
                >
                  Empty bucket
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={loading || busy}
                  onClick={() => setConfirm('delete-bucket')}
                >
                  Delete bucket
                </button>
              </div>
            </>
          ) : (
            <>
              <h2 className="aws-section-title">
                Objects ({loading ? '…' : `${filtered.length}/${objects.length}`}){' '}
                <InfoButton />
              </h2>
              <p className="aws-desc">
                Objects are the fundamental entities stored in Amazon S3. For
                others to access your objects, you&apos;ll need to explicitly
                grant them permissions.{' '}
                <a
                  href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingObjects.html"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Learn more ↗
                </a>
              </p>
              <div className="aws-toolbar">
                <RefreshButton onClick={() => void refresh()} />
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={selectedKeys.length !== 1}
                  onClick={() => void copyS3Uri()}
                >
                  Copy S3 URI
                </button>
                <DeadButton>Copy URL</DeadButton>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={selectedKeys.length === 0 || busy}
                  onClick={() => void onDownloadSelected()}
                >
                  Download
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={selectedKeys.length !== 1 || busy}
                  onClick={() => setPreviewKey(selectedKeys[0] ?? null)}
                >
                  Open ↗
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={selectedKeys.length === 0 || busy}
                  onClick={() => setConfirm('delete-objects')}
                >
                  Delete
                </button>
                <div className="aws-pop">
                  <button
                    type="button"
                    className="btn btn-normal"
                    aria-expanded={actionsOpen}
                    aria-controls="menu-actions"
                    onClick={() => setActionsOpen((v) => !v)}
                  >
                    Actions ▾
                  </button>
                  <div
                    className={`aws-menu left${actionsOpen ? ' open' : ''}`}
                    id="menu-actions"
                  >
                    {dead('Edit metadata')}
                    {dead('Edit storage class')}
                    {dead('Share with a presigned URL')}
                    <div className="sep" />
                    {dead('Rename object')}
                  </div>
                </div>
                <div className="spacer" />
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() => fileRef.current?.click()}
                >
                  ↑ Upload
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
              <TableTools
                placeholder="Find objects by prefix"
                value={prefix}
                onChange={setPrefix}
              />
              <div className="aws-table-wrap">
                <table className="aws-table">
                  <thead>
                    <tr>
                      <th className="check" scope="col">
                        <input
                          type="checkbox"
                          checked={allVisibleSelected}
                          aria-label="Select all objects"
                          onChange={toggleAllVisible}
                        />
                      </th>
                      <th scope="col">
                        <span className="th-inner">
                          Name <span aria-hidden="true">↑</span>
                        </span>
                      </th>
                      <th scope="col">Type</th>
                      <th scope="col">Last modified</th>
                      <th scope="col">Size</th>
                      <th scope="col">Storage class</th>
                    </tr>
                  </thead>
                  <tbody>
                    {loading ? (
                      <tr>
                        <td className="empty-cell" colSpan={6}>
                          Loading objects…
                        </td>
                      </tr>
                    ) : filtered.length === 0 ? (
                      <tr>
                        <td className="empty-cell" colSpan={6}>
                          <strong>No objects</strong>
                          This bucket is empty. Upload a file to get started.
                        </td>
                      </tr>
                    ) : (
                      filtered.map((o) => {
                        const key = o.Key ?? ''
                        const isSelected = selected.has(key)
                        return (
                          <tr
                            key={key}
                            className={`selectable${isSelected ? ' selected' : ''}`}
                            onClick={() => toggleKey(key)}
                          >
                            <td
                              className="check"
                              onClick={(e) => e.stopPropagation()}
                            >
                              <input
                                type="checkbox"
                                checked={isSelected}
                                aria-label={`Select ${key}`}
                                onChange={() => toggleKey(key)}
                              />
                            </td>
                            <td>
                              <button
                                type="button"
                                className="aws-link-btn"
                                onClick={(e) => {
                                  e.stopPropagation()
                                  setPreviewKey(key)
                                }}
                              >
                                {key}
                              </button>
                            </td>
                            <td>{objectType(key)}</td>
                            <td>
                              {o.LastModified
                                ? formatConsoleDate(o.LastModified)
                                : '—'}
                            </td>
                            <td>{formatBytes(o.Size ?? 0)}</td>
                            <td>STANDARD</td>
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

      {previewKey ? (
        <ObjectPreview
          bucket={bucket}
          objectKey={previewKey}
          onClose={() => setPreviewKey(null)}
          onDownload={(key) => {
            void downloadKeys([key])
          }}
        />
      ) : null}

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
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
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
                className="btn btn-normal"
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
