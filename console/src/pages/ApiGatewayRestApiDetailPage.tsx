import { useCallback, useEffect, useState } from 'react'
import type { FunctionConfiguration } from '@aws-sdk/client-lambda'
import { Link, useParams } from 'react-router-dom'
import { DeadButton, RefreshButton } from '../components/S3Ui'
import {
  DetailHeader,
  EmptyRow,
  Kv,
  Mono,
  Notices,
  PlainHeader,
  SelectCell,
  SelectHeader,
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
  updateRestMethodIntegration,
  type RestApiDetail,
  type RestIntegrationType,
  type RestResourceMethodRow,
} from '../lib/apigwRest'
import { listFunctions } from '../lib/lambda'

type DetailTab =
  | 'overview'
  | 'invoke'
  | 'resources'
  | 'authorizers'
  | 'stages'

type Panel = 'deploy' | 'resource' | 'method' | 'edit-integration' | null

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

const INTEGRATION_HTTP_METHODS = [
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'HEAD',
  'OPTIONS',
  'ANY',
] as const

const WIRED_INTEGRATION_TYPES: ReadonlyArray<{
  value: RestIntegrationType
  label: string
}> = [
  { value: 'MOCK', label: 'MOCK' },
  { value: 'AWS_PROXY', label: 'Lambda function (AWS_PROXY)' },
  { value: 'HTTP_PROXY', label: 'HTTP proxy' },
]

const DISABLED_INTEGRATION_TYPES = [
  { value: 'AWS', label: 'AWS (non-proxy)' },
  { value: 'HTTP', label: 'HTTP (non-proxy)' },
  { value: 'VPC_LINK', label: 'VPC link' },
] as const

function rowKey(r: RestResourceMethodRow): string {
  return `${r.resourceId}:${r.method}`
}

function functionNameFromUri(uri: string | null): string {
  if (!uri) return ''
  const m = /:function:([^/]+)/.exec(uri)
  return m?.[1] ?? ''
}

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
  const [integrationType, setIntegrationType] =
    useState<RestIntegrationType>('MOCK')
  const [lambdaFnName, setLambdaFnName] = useState('')
  const [httpUri, setHttpUri] = useState('')
  const [integrationHttpMethod, setIntegrationHttpMethod] = useState('POST')
  const [fns, setFns] = useState<FunctionConfiguration[]>([])
  const [selectedRow, setSelectedRow] = useState<string | null>(null)
  const [editTarget, setEditTarget] = useState<RestResourceMethodRow | null>(
    null,
  )

  const refresh = useCallback(async () => {
    if (!apiId) return
    setLoading(true)
    setError(null)
    try {
      const [next, functions] = await Promise.all([
        getRestApiDetail(apiId),
        listFunctions(),
      ])
      setDetail(next)
      setFns(functions)
      setLambdaFnName((prev) => {
        if (prev && functions.some((f) => f.FunctionName === prev)) return prev
        return functions[0]?.FunctionName ?? ''
      })
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
      setSelectedRow((cur) =>
        cur && next.resources.some((r) => rowKey(r) === cur) ? cur : null,
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

  function resetIntegrationFields(type: RestIntegrationType = 'MOCK') {
    setIntegrationType(type)
    setHttpUri('')
    setIntegrationHttpMethod('POST')
    setLambdaFnName((prev) => prev || fns[0]?.FunctionName || '')
  }

  function openCreateMethod() {
    resetIntegrationFields('MOCK')
    setPanel('method')
  }

  function openEditIntegration() {
    const row = detail?.resources.find((r) => rowKey(r) === selectedRow)
    if (!row || row.method === '—' || !row.resourceId) {
      setError('Select a method row to edit its integration')
      return
    }
    const type: RestIntegrationType =
      row.integrationType === 'AWS_PROXY' ||
      row.integrationType === 'HTTP_PROXY' ||
      row.integrationType === 'MOCK'
        ? row.integrationType
        : 'MOCK'
    setEditTarget(row)
    setIntegrationType(type)
    setHttpUri(type === 'HTTP_PROXY' ? (row.integrationUri ?? '') : '')
    setIntegrationHttpMethod('POST')
    setLambdaFnName(
      type === 'AWS_PROXY'
        ? functionNameFromUri(row.integrationUri) ||
            fns[0]?.FunctionName ||
            ''
        : fns[0]?.FunctionName || '',
    )
    setPanel('edit-integration')
  }

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
    if (integrationType === 'AWS_PROXY' && !lambdaFnName) {
      setError('Lambda function is required')
      return
    }
    if (integrationType === 'HTTP_PROXY' && !httpUri.trim()) {
      setError('HTTP endpoint URI is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await createRestMethod({
        apiId,
        resourceId: methodResourceId,
        httpMethod,
        integrationType,
        lambdaFunctionName: lambdaFnName,
        httpUri: httpUri.trim(),
        integrationHttpMethod,
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

  async function onEditIntegration() {
    if (!editTarget || editTarget.method === '—') {
      setError('Select a method row to edit its integration')
      return
    }
    if (integrationType === 'AWS_PROXY' && !lambdaFnName) {
      setError('Lambda function is required')
      return
    }
    if (integrationType === 'HTTP_PROXY' && !httpUri.trim()) {
      setError('HTTP endpoint URI is required')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await updateRestMethodIntegration({
        apiId,
        resourceId: editTarget.resourceId,
        httpMethod: editTarget.method,
        integrationType,
        lambdaFunctionName: lambdaFnName,
        httpUri: httpUri.trim(),
        integrationHttpMethod,
      })
      setPanel(null)
      setEditTarget(null)
      setTab('resources')
      await refresh()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  function renderIntegrationFields(testPrefix: string) {
    return (
      <>
        <label htmlFor={`${testPrefix}-type`}>Integration type</label>
        <select
          id={`${testPrefix}-type`}
          value={integrationType}
          onChange={(e) => {
            const next = e.target.value
            if (
              next === 'MOCK' ||
              next === 'AWS_PROXY' ||
              next === 'HTTP_PROXY'
            ) {
              setIntegrationType(next)
            }
          }}
          data-testid={`${testPrefix}-type`}
        >
          {WIRED_INTEGRATION_TYPES.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
          {DISABLED_INTEGRATION_TYPES.map((t) => (
            <option key={t.value} value={t.value} disabled title="To implement">
              {t.label}
            </option>
          ))}
        </select>
        {integrationType === 'AWS_PROXY' ? (
          <>
            <label htmlFor={`${testPrefix}-lambda`}>Lambda function</label>
            <select
              id={`${testPrefix}-lambda`}
              value={lambdaFnName}
              onChange={(e) => setLambdaFnName(e.target.value)}
              data-testid={`${testPrefix}-lambda`}
              disabled={fns.length === 0}
            >
              {fns.length === 0 ? (
                <option value="">No functions</option>
              ) : (
                fns.map((f) => (
                  <option key={f.FunctionArn} value={f.FunctionName ?? ''}>
                    {f.FunctionName}
                  </option>
                ))
              )}
            </select>
          </>
        ) : null}
        {integrationType === 'HTTP_PROXY' ? (
          <>
            <label htmlFor={`${testPrefix}-uri`}>HTTP endpoint</label>
            <input
              id={`${testPrefix}-uri`}
              type="url"
              value={httpUri}
              onChange={(e) => setHttpUri(e.target.value)}
              placeholder="http://127.0.0.1:8080/path"
              data-testid={`${testPrefix}-uri`}
            />
            <label htmlFor={`${testPrefix}-integ-http`}>
              Integration HTTP method
            </label>
            <select
              id={`${testPrefix}-integ-http`}
              value={integrationHttpMethod}
              onChange={(e) => setIntegrationHttpMethod(e.target.value)}
              data-testid={`${testPrefix}-integ-http`}
            >
              {INTEGRATION_HTTP_METHODS.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
          </>
        ) : null}
        {integrationType === 'MOCK' ? (
          <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
            MOCK returns 200 with a stub mapping template.
          </p>
        ) : null}
      </>
    )
  }

  const selectedMethodRow = detail?.resources.find(
    (r) => rowKey(r) === selectedRow && r.method !== '—',
  )

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
                  onClick={openCreateMethod}
                  data-testid="rest-create-method-open"
                >
                  Create method
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled={!selectedMethodRow}
                  title={
                    selectedMethodRow
                      ? undefined
                      : 'Select a method row'
                  }
                  onClick={openEditIntegration}
                  data-testid="rest-edit-integration-open"
                >
                  Edit integration
                </button>
              </div>
              <div className="aws-table-wrap">
                <table className="aws-table" data-testid="rest-resources-table">
                  <thead>
                    <tr>
                      <SelectHeader />
                      <PlainHeader>Resource</PlainHeader>
                      <PlainHeader>Method</PlainHeader>
                      <PlainHeader>Integration</PlainHeader>
                      <PlainHeader>Authorization</PlainHeader>
                    </tr>
                  </thead>
                  <tbody>
                    {(detail?.resources.length ?? 0) === 0 ? (
                      <EmptyRow
                        colSpan={5}
                        loading={loading}
                        loadingText="Loading resources…"
                        title="No resources"
                        text="This API has no resources yet."
                      />
                    ) : (
                      detail?.resources.map((r, i) => {
                        const key = rowKey(r)
                        const selectable =
                          r.method !== '—' && Boolean(r.resourceId)
                        const isSelected = selectedRow === key
                        return (
                          <tr
                            key={`${r.path}-${r.method}-${i}`}
                            className={
                              selectable
                                ? `selectable${isSelected ? ' selected' : ''}`
                                : undefined
                            }
                            onClick={
                              selectable
                                ? () =>
                                    setSelectedRow((cur) =>
                                      cur === key ? null : key,
                                    )
                                : undefined
                            }
                          >
                            {selectable ? (
                              <SelectCell
                                name="selected-rest-method"
                                id={key}
                                selected={isSelected}
                                onToggle={(id) =>
                                  setSelectedRow((cur) =>
                                    cur === id ? null : id,
                                  )
                                }
                              />
                            ) : (
                              <td className="check" />
                            )}
                            <td>
                              <Mono>{r.path}</Mono>
                            </td>
                            <td>{r.method}</td>
                            <td>{r.integration}</td>
                            <td>{r.authorization}</td>
                          </tr>
                        )
                      })
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
              Adds NONE authorization and the integration type you pick.
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
            {renderIntegrationFields('rest-create-method')}
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

      {panel === 'edit-integration' && editTarget ? (
        <div className="modal-backdrop">
          <div className="modal" data-testid="rest-edit-integration-modal">
            <h3>Edit integration</h3>
            <p style={{ color: 'var(--awsbox-quiet)', marginTop: 0 }}>
              {editTarget.method} {editTarget.path}
            </p>
            {renderIntegrationFields('rest-edit-integration')}
            <div className="modal-actions">
              <button
                type="button"
                className="btn btn-normal"
                disabled={busy}
                onClick={() => {
                  setPanel(null)
                  setEditTarget(null)
                }}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy}
                onClick={() => void onEditIntegration()}
                data-testid="rest-edit-integration-submit"
              >
                {busy ? 'Saving…' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  )
}
