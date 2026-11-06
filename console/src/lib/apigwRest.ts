import {
  APIGatewayClient,
  GetAuthorizersCommand,
  GetResourcesCommand,
  GetRestApiCommand,
  GetRestApisCommand,
  GetStagesCommand,
  type Authorizer,
  type Resource,
  type RestApi,
  type Stage,
} from '@aws-sdk/client-api-gateway'
import { config } from './config'
import { emuCreds } from './emu'

function restClient(): APIGatewayClient {
  return new APIGatewayClient(emuCreds())
}

export type RestApiRow = RestApi

export type RestResourceMethodRow = {
  path: string
  method: string
  integration: string
  authorization: string
}

export type RestApiDetail = {
  api: RestApi
  resources: RestResourceMethodRow[]
  authorizers: Authorizer[]
  stages: Stage[]
}

export async function listRestApis(): Promise<RestApiRow[]> {
  const out = await restClient().send(new GetRestApisCommand({}))
  return out.items ?? []
}

function integrationLabel(
  type: string | undefined,
  uri: string | undefined,
): string {
  if (!type) return '—'
  if (type === 'AWS_PROXY' || type === 'AWS') {
    return uri?.includes(':function:')
      ? `Lambda (${type.toLowerCase()})`
      : type
  }
  if (type === 'HTTP_PROXY' || type === 'HTTP') return type
  if (type === 'MOCK') return 'MOCK'
  return type
}

function authorizationLabel(
  authType: string | undefined,
  authorizerId: string | undefined,
  authorizers: Authorizer[],
): string {
  if (!authType || authType === 'NONE') return 'NONE'
  if (authType === 'REQUEST' || authType === 'TOKEN' || authType === 'COGNITO_USER_POOLS') {
    const name = authorizers.find((a) => a.id === authorizerId)?.name
    return name ? `${authType} · ${name}` : authType
  }
  return authType
}

function flattenResources(
  resources: Resource[],
  authorizers: Authorizer[],
): RestResourceMethodRow[] {
  const rows: RestResourceMethodRow[] = []
  const sorted = [...resources].sort((a, b) =>
    (a.path ?? '').localeCompare(b.path ?? ''),
  )
  for (const r of sorted) {
    const path = r.path ?? '/'
    const methods = r.resourceMethods
    if (!methods || Object.keys(methods).length === 0) {
      rows.push({
        path,
        method: '—',
        integration: '—',
        authorization: '—',
      })
      continue
    }
    for (const [method, detail] of Object.entries(methods)) {
      const integ = detail.methodIntegration
      rows.push({
        path,
        method,
        integration: integrationLabel(integ?.type, integ?.uri),
        authorization: authorizationLabel(
          detail.authorizationType,
          detail.authorizerId,
          authorizers,
        ),
      })
    }
  }
  return rows
}

export async function getRestApiDetail(apiId: string): Promise<RestApiDetail> {
  const client = restClient()
  const [api, resourcesOut, authorizersOut, stagesOut] = await Promise.all([
    client.send(new GetRestApiCommand({ restApiId: apiId })),
    client.send(
      new GetResourcesCommand({ restApiId: apiId, embed: ['methods'] }),
    ),
    client.send(new GetAuthorizersCommand({ restApiId: apiId })),
    client.send(new GetStagesCommand({ restApiId: apiId })),
  ])
  const authorizers = authorizersOut.items ?? []
  return {
    api,
    resources: flattenResources(resourcesOut.items ?? [], authorizers),
    authorizers,
    stages: stagesOut.item ?? [],
  }
}

/** LocalEmu REST invoke base (docs/apigw-rest.md). */
export function localRestInvokeUrl(apiId: string, stage: string): string {
  const base = config.iamEndpoint.replace(/\/$/, '')
  return `${base}/restapis/${apiId}/${stage}/_user_request_/`
}

export function browserRestInvokeUrl(apiId: string, stage: string): string {
  if (typeof window !== 'undefined' && window.location?.origin) {
    return `${window.location.origin}/aws-iam/restapis/${apiId}/${stage}/_user_request_/`
  }
  return localRestInvokeUrl(apiId, stage)
}

/** List-column endpoint: first stage LocalEmu URL, else API root path. */
export function restListEndpoint(apiId: string, stage?: string): string {
  if (stage) return localRestInvokeUrl(apiId, stage)
  const base = config.iamEndpoint.replace(/\/$/, '')
  return `${base}/restapis/${apiId}/`
}

export function endpointTypeLabel(api: RestApi): string {
  const t = api.endpointConfiguration?.types?.[0]
  if (!t) return 'Regional'
  if (t === 'EDGE') return 'Edge'
  if (t === 'PRIVATE') return 'Private'
  return 'Regional'
}

export function authorizerLambdaLabel(uri: string | undefined): string {
  if (!uri) return '—'
  const m = /functions\/(arn:aws:lambda:[^/]+)\/invocations/.exec(uri)
  return m?.[1] ?? uri
}
