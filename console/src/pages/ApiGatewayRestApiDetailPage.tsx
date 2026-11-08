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
  createRestMethod,
  createRestResource,
  deployRestApi,
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

type Panel = 'deploy' | 'resource' | 'method' | null

const TABS: ReadonlyArray<readonly [DetailTab, string]> = [
  ['overview', 'Overview'],
  ['invoke', 'Invoke URL'],
  ['resources', 'Resources'],
  ['authorizers', 'Authorizers'],
  ['stages', 'Stages'],
]

const HTTP_METHODS = [
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'HEAD',
  'OPTIONS',
  'ANY',
] as const

function restRootHint(apiId: string): string {
  return browserRestInvokeUrl(apiId, '<stage>').replace(
    '/<stage>/_user_request_/',
    '/',
  )
}

export function ApiGatewayRestApiDetailPage() {
  const { apiId: rawId } = useParams()
  const apiId = rawId ? decodeURIComponent(rawId) : ''
  const [detail, setDetail] = useState<RestApiDetail | null>(null)
  const [tab, setTab] = useState<DetailTab>('overview')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [panel, setPanel] = useState<Panel>(null)
  const [busy, setBusy] = useState(false)

  const [stageName, setStageName] = useState('prod')
  const [deployDesc, setDeployDesc] = useState('')
  const [pathPart, setPathPart] = useState('')
  const [parentId, setParentId] = useState('')
  const [methodResourceId, setMethodResourceId] = useState('')
  const [httpMethod, setHttpMethod] = useState<string>('GET')

  const refresh = useCallback(async () => {
    if (!apiId) return
    setLoading(true)
    setError(null)
    try {
      const next = await getRestApiDetail(apiId)
      setDetail(next)
      const root =
        next.resourceNodes.find((n) => n.path === '/')?.id ??
        next.resourceNodes[0]?.id ??
        ''
      setParentId((cur) =>
        cur && next.resourceNodes.some((n) => n.id === cur) ? cur : root,
      )
      setMethodResourceId((cur) =>
        cur && next.resourceNodes.some((n) => n.id === cur) ? cur : root,
      )
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
  const nodes = detail?.resourceNodes ?? []

  async function onDeploy() {
    const stage = stageName.trim()
    if (!stage) {
      setError('Stage name is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await deployRestApi({
        apiId,
        stageName: stage,
        description: deployDesc.trim() || undefined,
      })
      setPanel(null)
      setTab('stages')
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onCreateResource() {
    const part = pathPart.trim()
    if (!part) {
      setError('Path part is required')
      return
    }
    if (!parentId) {
      setError('Parent resource is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createRestResource({ apiId, parentId, pathPart: part })
      setPathPart('')
      setPanel(null)
      setTab('resources')
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  async function onCreateMethod() {
    if (!methodResourceId) {
      setError('Resource is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createRestMethod({
        apiId,
        resourceId: methodResourceId,
        httpMethod,
      })
      setPanel(null)
      setTab('resources')
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

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
            <RefreshButton onClick={() => void refresh()} disabled={loading} />
            <DeadButton>Actions ▾</DeadButton>
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => setPanel('deploy')}
              data-testid="rest-api-deploy-open"
            >
              Deploy API
            </button>
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
                  [
                    'Description',
                    api.description?.trim() ? api.description : '—',
                  ],
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
                <button
                  type="button"
                  className="btn btn-normal"
                  onClick={() => setPanel('resource')}
                  data-testid="rest-create-resource-open"
                >
                  Create resource
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  onClick={() => setPanel('method')}
                  data-testid="rest-create-method-open"
                >
                  Create method
                </button>
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
                            <td>
                              {s.description?.trim() ? s.description : '—'}
                            </td>
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

      {panel === 'deploy' ? (
        <div className="modal-backdrop">
          <div className="modal" data-testid="rest-api-deploy-modal">
            <h3>Deploy API</h3>
            <label htmlFor="stage-name">Stage name</label>
            <input
              id="stage-name"
              value={stageName}
              onChange={(e) => setStageName(e.target.value)}
              placeholder="prod"
              autoFocus
              data-testid="rest-api-deploy-stage"
            />
            <label htmlFor="deploy-desc">Deployment description</label>
            <input
              id="deploy-desc"
              value={deployDesc}
              onChange={(e) => setDeployDesc(e.target.value)}
              placeholder="Optional"
              data-testid="rest-api-deploy-description"
            />
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setPanel(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onDeploy()}
                data-testid="rest-api-deploy-submit"
              >
                {busy ? 'Deploying…' : 'Deploy'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {panel === 'resource' ? (
        <div className="modal-backdrop">
          <div className="modal" data-testid="rest-create-resource-modal">
            <h3>Create resource</h3>
            <label htmlFor="parent-resource">Parent resource</label>
            <select
              id="parent-resource"
              value={parentId}
              onChange={(e) => setParentId(e.target.value)}
              data-testid="rest-create-resource-parent"
            >
              {nodes.map((n) => (
                <option key={n.id} value={n.id}>
                  {n.path}
                </option>
              ))}
            </select>
            <label htmlFor="path-part">Path part</label>
            <input
              id="path-part"
              value={pathPart}
              onChange={(e) => setPathPart(e.target.value)}
              placeholder="orders"
              autoFocus
              data-testid="rest-create-resource-path"
            />
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setPanel(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onCreateResource()}
                data-testid="rest-create-resource-submit"
              >
                {busy ? 'Creating…' : 'Create'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {panel === 'method' ? (
        <div className="modal-backdrop">
          <div className="modal" data-testid="rest-create-method-modal">
            <h3>Create method</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              Adds NONE authorization with a MOCK integration (200).
            </p>
            <label htmlFor="method-resource">Resource</label>
            <select
              id="method-resource"
              value={methodResourceId}
              onChange={(e) => setMethodResourceId(e.target.value)}
              data-testid="rest-create-method-resource"
            >
              {nodes.map((n) => (
                <option key={n.id} value={n.id}>
                  {n.path}
                </option>
              ))}
            </select>
            <label htmlFor="http-method">HTTP method</label>
            <select
              id="http-method"
              value={httpMethod}
              onChange={(e) => setHttpMethod(e.target.value)}
              data-testid="rest-create-method-http"
            >
              {HTTP_METHODS.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => setPanel(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onCreateMethod()}
                data-testid="rest-create-method-submit"
              >
                {busy ? 'Creating…' : 'Create'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
