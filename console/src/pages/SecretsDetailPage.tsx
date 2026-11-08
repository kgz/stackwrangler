import { useCallback, useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import { Kv, Mono, Notices, StatusBadge } from '../components/ServiceUi'
import { formatServiceDate } from '../lib/format'
import {
  describeSecret,
  getSecretString,
  listSecretVersions,
  type SecretDetail,
  type SecretVersionsListEntry,
} from '../lib/secrets'

type DetailTab = 'overview' | 'versions'

export function SecretsDetailPage() {
  const params = useParams()
  const secretId = params['*'] ? decodeURIComponent(params['*']) : ''
  const [tab, setTab] = useState<DetailTab>('overview')
  const [meta, setMeta] = useState<SecretDetail | null>(null)
  const [versions, setVersions] = useState<SecretVersionsListEntry[]>([])
  const [versionsLoaded, setVersionsLoaded] = useState(false)
  const [secretValue, setSecretValue] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refreshMeta = useCallback(async () => {
    if (!secretId) return
    setLoading(true)
    setError(null)
    try {
      const detail = await describeSecret(secretId)
      setMeta(detail)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [secretId])

  const loadVersions = useCallback(async () => {
    if (!secretId) return
    setBusy(true)
    setError(null)
    try {
      const list = await listSecretVersions(secretId)
      setVersions(list)
      setVersionsLoaded(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }, [secretId])

  useEffect(() => {
    void refreshMeta()
  }, [refreshMeta])

  useEffect(() => {
    if (tab === 'versions' && !versionsLoaded) {
      void loadVersions()
    }
  }, [tab, versionsLoaded, loadVersions])

  async function onRetrieve() {
    if (!secretId) return
    setBusy(true)
    setError(null)
    try {
      const value = await getSecretString(secretId)
      setSecretValue(value)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  if (!secretId) {
    return <p className="aws-desc">Missing secret name.</p>
  }

  const title = meta?.name || secretId
  const deleted = Boolean(meta?.deletedDate)

  return (
    <>
      <div className="aws-toolbar">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1" style={{ margin: 0 }}>
            <ResourceLabel ids={[title, meta?.arn]} detail>
              {title}
            </ResourceLabel>
          </h1>
          {meta ? (
            <div className="aws-subtitle-row">
              <StatusBadge
                status={deleted ? 'Deleted' : 'Available'}
                label={deleted ? 'Pending deletion' : 'Available'}
              />
              <span>Created {formatServiceDate(meta.createdDate)}</span>
              <span>
                Last retrieved {formatServiceDate(meta.lastAccessedDate)}
              </span>
            </div>
          ) : null}
        </div>
        <RefreshButton
          onClick={() => {
            setVersionsLoaded(false)
            setSecretValue(null)
            void refreshMeta()
          }}
        />
        <DeadButton>Delete</DeadButton>
        <DeadButton>Rotate</DeadButton>
        <DeadButton>Actions ▾</DeadButton>
      </div>

      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          <button
            type="button"
            className={`aws-tab${tab === 'overview' ? ' active' : ''}`}
            aria-current={tab === 'overview' ? 'page' : undefined}
            onClick={() => setTab('overview')}
          >
            Overview
          </button>
          <button
            type="button"
            className={`aws-tab${tab === 'versions' ? ' active' : ''}`}
            aria-current={tab === 'versions' ? 'page' : undefined}
            onClick={() => setTab('versions')}
            data-testid="secrets-tab-versions"
          >
            Versions
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Rotation
          </button>
          <button
            type="button"
            className="aws-tab"
            disabled
            aria-disabled="true"
            title="To implement"
          >
            Resource permission
          </button>
        </div>
        <div className="aws-card-body">
          {loading && tab === 'overview' ? (
            <p className="aws-desc">Loading…</p>
          ) : null}

          {!loading && tab === 'overview' && meta ? (
            <>
              <h2 className="aws-section-title">Secret details</h2>
              <Kv
                rows={[
                  ['Secret name', title],
                  ['Secret ARN', <Mono key="arn">{meta.arn || '—'}</Mono>],
                  [
                    'Description',
                    meta.description.trim() ? meta.description : '—',
                  ],
                  [
                    'Encryption key',
                    <Mono key="kms">{meta.kmsKeyId}</Mono>,
                  ],
                  ['Created on', formatServiceDate(meta.createdDate)],
                  [
                    'Last retrieved',
                    formatServiceDate(meta.lastAccessedDate),
                  ],
                  ['Last changed', formatServiceDate(meta.lastChangedDate)],
                ]}
              />

              <h2 className="aws-section-title" style={{ marginTop: 24 }}>
                Secret value
              </h2>
              <p className="aws-desc" style={{ marginBottom: 12 }}>
                Values are not shown until you retrieve them. LocalEmu supports{' '}
                <code className="aws-mono">GetSecretValue</code>; retrieval is
                gated behind an explicit action.
              </p>
              <div className="aws-toolbar" style={{ marginBottom: 12 }}>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={busy || secretValue != null}
                  onClick={() => void onRetrieve()}
                  data-testid="retrieve-secret-value"
                >
                  {busy && secretValue == null
                    ? 'Retrieving…'
                    : 'Retrieve secret value'}
                </button>
              </div>
              {secretValue == null ? (
                <div className="aws-empty-panel" data-testid="secret-value-hidden">
                  <strong>Secret value hidden</strong>
                  <p>
                    Choose Retrieve secret value to call LocalEmu and show the
                    current AWSCURRENT string.
                  </p>
                </div>
              ) : (
                <pre
                  className="aws-code-source"
                  style={{
                    whiteSpace: 'pre-wrap',
                    padding: 12,
                    border: '1px solid var(--aws-border, #d5dbdb)',
                    background: 'var(--aws-surface-2, #fafafa)',
                  }}
                  data-testid="secret-value-text"
                >
                  {secretValue}
                </pre>
              )}
            </>
          ) : null}

          {tab === 'versions' ? (
            <>
              <h2 className="aws-section-title">Versions</h2>
              <p className="aws-desc" style={{ marginBottom: 12 }}>
                Staging labels from{' '}
                <code className="aws-mono">ListSecretVersionIds</code> as
                LocalEmu returns them.
              </p>
              {busy && !versionsLoaded ? (
                <p className="aws-desc">Loading versions…</p>
              ) : (
                <div className="aws-table-wrap">
                  <table
                    className="aws-table"
                    data-testid="secret-versions-table"
                  >
                    <thead>
                      <tr>
                        <th scope="col">
                          <span className="th-inner">Version ID</span>
                        </th>
                        <th scope="col">
                          <span className="th-inner">Staging labels</span>
                        </th>
                        <th scope="col">
                          <span className="th-inner">Created</span>
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {versions.length === 0 ? (
                        <tr>
                          <td colSpan={3}>No versions</td>
                        </tr>
                      ) : (
                        versions.map((v) => {
                          const id = v.VersionId ?? '—'
                          const labels = (v.VersionStages ?? []).join(', ')
                          return (
                            <tr key={id}>
                              <td>
                                <Mono>{id}</Mono>
                              </td>
                              <td>{labels || '—'}</td>
                              <td>{formatServiceDate(v.CreatedDate)}</td>
                            </tr>
                          )
                        })
                      )}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          ) : null}
        </div>
      </section>
    </>
  )
}
