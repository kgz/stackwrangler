import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { DeadButton, RefreshButton } from '../components/S3Ui'
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
  authorizerLambdaLabel,
  browserRestInvokeUrl,
  endpointTypeLabel,
  getRestApiDetail,
  type RestApiDetail,
} from '../lib/apigwRest'

type DetailTab =
  | 'overview'
  | 'invoke'
  | 'resources'
  | 'authorizers'
  | 'stages'

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['overview', 'Overview'],
  ['invoke', 'Invoke URL'],
  ['resources', 'Resources'],
  ['authorizers', 'Authorizers'],
  ['stages', 'Stages'],
]

export function ApiGatewayRestApiDetailPage() {
  const { apiId: rawId } = useParams()
  const apiId = rawId ? decodeURIComponent(rawId) : ''
  const [detail, setDetail] = useState<RestApiDetail | null>(null)
  const [tab, setTab] = useState<DetailTab>('overview')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    if (!apiId) return
    setLoading(true)
    setError(null)
    try {
      setDetail(await getRestApiDetail(apiId))
    } catch (err) {
      setDetail(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [apiId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const api = detail?.api
  const name = api?.name ?? apiId
  const stages = detail?.stages ?? []

  return (
    <>
      <DetailHeader
        title={name}
        subtitle={
          <>
            <span>REST</span>
            <span>{api ? endpointTypeLabel(api) : '—'}</span>
            <span>Created {formatServiceDate(api?.createdDate)}</span>
          </>
        }
        actions={
          <>
            <RefreshButton />
            <DeadButton>Actions ▾</DeadButton>
            <DeadButton variant="primary">Deploy API</DeadButton>
          </>
        }
      />
      <p className="aws-desc">
        <Link to="/apigateway/rest-apis">← REST APIs</Link>
      </p>
      <Notices error={error} />

      <section className="aws-card">
        <div className="aws-tabs" role="tablist">
          {TABS.map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`aws-tab${tab === id ? ' active' : ''}`}
              aria-current={tab === id ? 'page' : undefined}
              onClick={() => setTab(id)}
              data-testid={`rest-api-tab-${id}`}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="aws-card-body">
          {loading && !detail ? <p className="aws-desc">Loading…</p> : null}

          {tab === 'overview' && api ? (
            <>
              <h2 className="aws-section-title">API details</h2>
              <Kv
                rows={[
                  ['Name', api.name ?? '—'],
                  ['API ID', <Mono key="id">{api.id ?? apiId}</Mono>],
                  ['Description', api.description?.trim() ? api.description : '—'],
                  ['API endpoint type', endpointTypeLabel(api)],
                  [
                    'API endpoint',
                    <Mono key="ep">
                      {stages[0]
                        ? browserRestInvokeUrl(apiId, stages[0].stageName ?? '')
                        : restRootHint(apiId)}
                    </Mono>,
                  ],
                  ['Created', formatServiceDate(api.createdDate)],
                  [
                    'Binary media types',
                    api.binaryMediaTypes?.length
                      ? api.binaryMediaTypes.join(', ')
                      : '—',
                  ],
                  [
                    'Minimum compression size',
                    api.minimumCompressionSize != null
                      ? String(api.minimumCompressionSize)
                      : 'None',
                  ],
                  ['API key source', api.apiKeySource ?? 'HEADER'],
                ]}
              />
            </>
          ) : null}

          {tab === 'invoke' ? (
            <>
              <h2 className="aws-section-title">Invoke URL</h2>
              <p className="aws-desc">
                Stage invoke URLs for this REST API. Append a resource path after
                the stage. LocalEmu edge form:{' '}
                <code>
                  /restapis/&lt;api-id&gt;/&lt;stage&gt;/_user_request_/&lt;path&gt;
                </code>
                .
              </p>
              {stages.length === 0 ? (
                <p className="aws-desc">No stages deployed yet.</p>
              ) : (
                <Kv
                  rows={stages.map((s) => {
                    const stage = s.stageName ?? '—'
                    return [
                      stage,
                      <Mono key={stage}>
                        {browserRestInvokeUrl(apiId, stage)}
                      </Mono>,
                    ]
                  })}
                />
              )}
            </>
          ) : null}

          {tab === 'resources' ? (
            <>
              <div className="aws-toolbar">
                <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
                  Resources
                </h2>
                <DeadButton>Create resource</DeadButton>
                <DeadButton>Create method</DeadButton>
              </div>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="rest-resources-table">
                  <thead>
                    <tr>
                      <PlainHeader>Resource</PlainHeader>
                      <PlainHeader>Method</PlainHeader>
                      <PlainHeader>Integration</PlainHeader>
                      <PlainHeader>Authorization</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {(detail?.resources.length ?? 0) === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={loading}
                        loadingText="Loading resources…"
                        title="No resources"
                        text="This API has no resources yet."
                      />
                    ) : (
                      detail?.resources.map((r, i) => (
                        <tr key={`${r.path}-${r.method}-${i}`}>
                          <td>
                            <Mono>{r.path}</Mono>
                          </td>
                          <td>{r.method}</td>
                          <td>{r.integration}</td>
                          <td>{r.authorization}</td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}

          {tab === 'authorizers' ? (
            <>
              <div className="aws-toolbar">
                <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
                  Authorizers
                </h2>
                <DeadButton>Create authorizer</DeadButton>
              </div>
              <div className="aws-table-wrap">
                <table
                  className="aws-table"
                  data-testid="rest-authorizers-table"
                >
                  <thead>
                    <tr>
                      <PlainHeader>Name</PlainHeader>
                      <PlainHeader>Type</PlainHeader>
                      <PlainHeader>Lambda function</PlainHeader>
                      <PlainHeader>Identity sources</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {(detail?.authorizers.length ?? 0) === 0 ? (
                      <EmptyRow
                        colSpan={4}
                        loading={loading}
                        loadingText="Loading authorizers…"
                        title="No authorizers"
                        text="This API has no authorizers."
                      />
                    ) : (
                      detail?.authorizers.map((a) => (
                        <tr key={a.id ?? a.name}>
                          <td>{a.name ?? '—'}</td>
                          <td>{a.type ?? '—'}</td>
                          <td>
                            <Mono>
                              {authorizerLambdaLabel(a.authorizerUri)}
                            </Mono>
                          </td>
                          <td>
                            <Mono>{a.identitySource ?? '—'}</Mono>
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}

          {tab === 'stages' ? (
            <>
              <div className="aws-toolbar">
                <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
                  Stages
                </h2>
                <DeadButton>Create</DeadButton>
              </div>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="rest-stages-table">
                  <thead>
                    <tr>
                      <PlainHeader>Stage</PlainHeader>
                      <PlainHeader>Deployment ID</PlainHeader>
                      <PlainHeader>Description</PlainHeader>
                      <PlainHeader>Last updated</PlainHeader>
                      <PlainHeader>Invoke URL</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {stages.length === 0 ? (
                      <EmptyRow
                        colSpan={5}
                        loading={loading}
                        loadingText="Loading stages…"
                        title="No stages"
                        text="Deploy the API to create a stage."
                      />
                    ) : (
                      stages.map((s) => {
                        const stage = s.stageName ?? '—'
                        return (
                          <tr key={stage}>
                            <td>{stage}</td>
                            <td>
                              <Mono>{s.deploymentId ?? '—'}</Mono>
                            </td>
                            <td>{s.description?.trim() ? s.description : '—'}</td>
                            <td>{formatServiceDate(s.lastUpdatedDate)}</td>
                            <td>
                              <Mono>
                                {browserRestInvokeUrl(apiId, stage)}
                              </Mono>
                            </td>
                          </tr>
                        )
                      })
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

function restRootHint(apiId: string): string {
  if (typeof window !== 'undefined' && window.location?.origin) {
    return `${window.location.origin}/aws-iam/restapis/${apiId}/`
  }
  return `/restapis/${apiId}/`
}
