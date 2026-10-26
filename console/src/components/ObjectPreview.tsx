import { useEffect, useState } from 'react'
import { formatBytes } from '../lib/format'
import {
  formatS3Error,
  getObject,
  previewKind,
  type ObjectPayload,
  type PreviewKind,
} from '../lib/s3'

const TEXT_LIMIT = 512 * 1024

type Props = {
  bucket: string
  objectKey: string
  onClose: () => void
  onDownload: (key: string) => void
}

export function ObjectPreview({
  bucket,
  objectKey,
  onClose,
  onDownload,
}: Props) {
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [payload, setPayload] = useState<ObjectPayload | null>(null)
  const [kind, setKind] = useState<PreviewKind>('binary')
  const [text, setText] = useState<string | null>(null)
  const [truncated, setTruncated] = useState(false)
  const [objectUrl, setObjectUrl] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    let url: string | null = null

    async function load() {
      setLoading(true)
      setError(null)
      setText(null)
      setTruncated(false)
      setPayload(null)
      try {
        const next = await getObject(bucket, objectKey)
        if (cancelled) return
        setPayload(next)
        const k = previewKind(next.contentType, objectKey)
        setKind(k)
        if (k === 'text') {
          const raw = await next.blob.text()
          if (cancelled) return
          if (raw.length > TEXT_LIMIT) {
            setText(raw.slice(0, TEXT_LIMIT))
            setTruncated(true)
          } else {
            setText(raw)
          }
        } else if (k === 'image') {
          url = URL.createObjectURL(next.blob)
          setObjectUrl(url)
        }
      } catch (err) {
        if (!cancelled) setError(formatS3Error(err))
      } finally {
        if (!cancelled) setLoading(false)
      }
    }

    void load()
    return () => {
      cancelled = true
      if (url) URL.revokeObjectURL(url)
    }
  }, [bucket, objectKey])

  useEffect(() => {
    return () => {
      if (objectUrl) URL.revokeObjectURL(objectUrl)
    }
  }, [objectUrl])

  return (
    <div className="modal-backdrop" role="presentation" onClick={onClose}>
      <div
        className="modal preview-modal"
        role="dialog"
        aria-labelledby="object-preview-title"
        onClick={(e) => e.stopPropagation()}
      >
        <h3 id="object-preview-title">Object: {objectKey}</h3>
        <p className="preview-meta">
          <code>
            s3://{bucket}/{objectKey}
          </code>
          {payload ? (
            <>
              {' '}
              · {payload.contentType} · {formatBytes(payload.contentLength)}
            </>
          ) : null}
        </p>

        {error ? <div className="error-banner">{error}</div> : null}
        {loading ? <p>Loading preview…</p> : null}

        {!loading && !error && kind === 'text' && text !== null ? (
          <>
            {truncated ? (
              <p className="preview-note">
                Showing first {formatBytes(TEXT_LIMIT)} of text.
              </p>
            ) : null}
            <pre className="preview-text" data-testid="object-preview-text">
              {text}
            </pre>
          </>
        ) : null}

        {!loading && !error && kind === 'image' && objectUrl ? (
          <div className="preview-image-wrap">
            <img
              src={objectUrl}
              alt={objectKey}
              data-testid="object-preview-image"
            />
          </div>
        ) : null}

        {!loading && !error && kind === 'binary' ? (
          <p className="preview-note" data-testid="object-preview-binary">
            No inline preview for this type. Download the object to open it
            locally.
          </p>
        ) : null}

        <div className="modal-actions">
          <button type="button" className="btn" onClick={onClose}>
            Close
          </button>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => onDownload(objectKey)}
          >
            Download
          </button>
        </div>
      </div>
    </div>
  )
}
