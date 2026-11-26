import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { RefreshButton, TO_IMPLEMENT } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  Kv,
  Mono,
  Notices,
  PlainHeader,
} from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  describeRepository,
  listRepositoryImages,
  type EcrImageRow,
  type EcrRepositoryRow,
} from '../lib/ecr'
import { config } from '../lib/config'

type DetailTab = 'details' | 'images'

type EcrDetail = EcrRepositoryRow & { scanDetail: string }

const LIVE_TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['details', 'Details'],
  ['images', 'Images'],
]

const DEAD_TABS: string[] = [
  'Permissions',
  'Lifecycle policy',
  'Scan settings',
]

export function EcrRepositoryDetailPage() {
  const { name: rawName } = useParams()
  const name = rawName ? decodeURIComponent(rawName) : ''
  const [detail, setDetail] = useState<EcrDetail | null>(null)
  const [images, setImages] = useState<EcrImageRow[]>([])
  const [tab, setTab] = useState<DetailTab>('details')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    if (!name) return
    setLoading(true)
    setError(null)
    try {
      const repo = await describeRepository(name)
      setDetail(repo)
      try {
        setImages(await listRepositoryImages(name))
      } catch {
        setImages([])
      }
    } catch (err) {
      setDetail(null)
      setImages([])
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [name])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const title = detail?.name ?? name

  return (
    <>
      <DetailHeader
        title={title}
        subtitle={
          detail ? (
            <>
              <span>Private</span>
              <span>
                <Mono>{detail.uri}</Mono>
              </span>
            </>
          ) : undefined
        }
        actions={
          <>
            <RefreshButton onClick={() => void refresh()} />
            <button
              type="button"
              className="btn btn-normal"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
              data-testid="ecr-detail-delete"
            >
              Delete
            </button>
            <button
              type="button"
              className="btn btn-normal"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
              data-testid="ecr-push-commands"
            >
              View push commands
            </button>
          </>
        }
      />

      <p className="aws-desc">
        <Link to="/ecr" data-testid="ecr-back-list">
          ← Private repositories
        </Link>
      </p>

      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist" data-testid="ecr-detail-tabs">
          {LIVE_TABS.map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`aws-tab${tab === id ? ' active' : ''}`}
              aria-current={tab === id ? 'page' : undefined}
              onClick={() => setTab(id)}
              data-testid={`ecr-tab-${id}`}
            >
              {label}
            </button>
          ))}
          {DEAD_TABS.map((label) => (
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
          ))}
        </div>
        <div className="aws-card-body">
          {loading && !detail ? (
            <p className="aws-desc">Loading repository…</p>
          ) : null}

          {tab === 'details' && detail ? (
            <>
              <h2 className="aws-section-title">Repository details</h2>
              <Kv
                rows={[
                  ['Repository name', detail.name],
                  ['Repository URI', <Mono key="uri">{detail.uri}</Mono>],
                  ['Repository ARN', <Mono key="arn">{detail.arn}</Mono>],
                  ['Created at', formatServiceDate(detail.createdAt)],
                  [
                    'Registry ID',
                    <Mono key="reg">{detail.registryId}</Mono>,
                  ],
                  ['Region', config.region],
                  ['Image tag mutability', detail.imageTagMutability],
                  ['Image scanning configuration', detail.scanDetail],
                  ['Encryption type', detail.encryptionType],
                ]}
              />
            </>
          ) : null}

          {tab === 'images' ? (
            <>
              <h2 className="aws-section-title">Images</h2>
              <p className="aws-desc">Image tags pushed to this repository.</p>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="ecr-images-table">
                  <thead>
                    <tr>
                      <PlainHeader>Image tag</PlainHeader>
                      <PlainHeader>Image digest</PlainHeader>
                      <PlainHeader>Last pushed</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {images.length === 0 ? (
                      <EmptyRow
                        colSpan={3}
                        loading={loading}
                        loadingText="Loading images…"
                        title="No images"
                        text="This repository does not have any images."
                      />
                    ) : (
                      images.map((img) => (
                        <tr key={`${img.digest}-${img.tag}`}>
                          <td>
                            <Mono>{img.tag}</Mono>
                          </td>
                          <td>
                            <Mono>{img.digest}</Mono>
                          </td>
                          <td>{formatServiceDate(img.pushedAt)}</td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}
        </div>
      </section>
    </>
  )
}
