import {
  APIGatewayClient,
  CreateDeploymentCommand,
  CreateResourceCommand,
  CreateRestApiCommand,
  DeleteRestApiCommand,
  GetAuthorizersCommand,
  GetResourcesCommand,
  GetRestApiCommand,
  GetRestApisCommand,
  GetStagesCommand,
  PutIntegrationCommand,
  PutIntegrationResponseCommand,
  PutMethodCommand,
  PutMethodResponseCommand,
  type Authorizer,
  type Resource,
  type RestApi,
  type Stage,
} from '@aws-sdk/client-api-gateway'
import {
  AddPermissionCommand,
  GetFunctionCommand,
  LambdaClient,
} from '@aws-sdk/client-lambda'
import { config } from './config'
import { emuCreds } from './emu'

/** Integration types LocalEmu can run from the console picker. */
export type RestIntegrationType = 'MOCK' | 'AWS_PROXY' | 'HTTP_PROXY'

export type RestMethodIntegrationInput = {
  apiId: string
  resourceId: string
  httpMethod: string
  integrationType: RestIntegrationType
  lambdaFunctionName?: string
  httpUri?: string
  integrationHttpMethod?: string
}

function restClient(): APIGatewayClient {
  return new APIGatewayClient(emuCreds())
}

export type RestApiRow = RestApi

export type RestResourceMethodRow = {
  resourceId: string
  path: string
  method: string
  integration: string
  integrationType: string | null
  integrationUri: string | null
  authorization: string
}

export type RestResourceNode = {
  id: string
  path: string
}

export type RestApiDetail = {
  api: RestApi
  resources: RestResourceMethodRow[]
  resourceNodes: RestResourceNode[]
  authorizers: Authorizer[]
  stages: Stage[]
}

export async function listRestApis(): Promise<RestApiRow[]> {
  const out = await restClient().send(new GetRestApisCommand({}))
  return out.items ?? []
}

export async function createRestApi(input: {
  name: string
  description?: string
}): Promise<string> {
  const out = await restClient().send(
    new CreateRestApiCommand({
      name: input.name,
      description: input.description,
      endpointConfiguration: { types: ['REGIONAL'] },
    }),
  )
  const id = out.id
  if (!id) throw new Error('CreateRestApi returned no id')
  return id
}

export async function deleteRestApi(apiId: string): Promise<void> {
  await restClient().send(new DeleteRestApiCommand({ restApiId: apiId }))
}

export async function deployRestApi(input: {
  apiId: string
  stageName: string
  description?: string
}): Promise<void> {
  await restClient().send(
    new CreateDeploymentCommand({
      restApiId: input.apiId,
      stageName: input.stageName,
      description: input.description,
    }),
  )
}

export async function createRestResource(input: {
  apiId: string
  parentId: string
  pathPart: string
}): Promise<string> {
  const out = await restClient().send(
    new CreateResourceCommand({
      restApiId: input.apiId,
      parentId: input.parentId,
      pathPart: input.pathPart,
    }),
  )
  const id = out.id
  if (!id) throw new Error('CreateResource returned no id')
  return id
}

function lambdaClient(): LambdaClient {
  return new LambdaClient(emuCreds())
}

function lambdaProxyUri(functionArn: string): string {
  return `arn:aws:apigateway:${config.region}:lambda:path/2015-03-31/functions/${functionArn}/invocations`
}

async function resolveLambdaArn(functionName: string): Promise<string> {
  const got = await lambdaClient().send(
    new GetFunctionCommand({ FunctionName: functionName }),
  )
  const arn = got.Configuration?.FunctionArn
  if (!arn) throw new Error(`Function ${functionName} has no ARN`)
  return arn
}

async function grantApiGatewayInvoke(
  apiId: string,
  functionName: string,
): Promise<void> {
  try {
    await lambdaClient().send(
      new AddPermissionCommand({
        FunctionName: functionName,
        StatementId: `apigw-rest-${apiId}-${functionName}`.replace(
          /[^A-Za-z0-9-_]/g,
          '-',
        ),
        Action: 'lambda:InvokeFunction',
        Principal: 'apigateway.amazonaws.com',
        SourceArn: `arn:aws:execute-api:${config.region}:${config.accountId}:${apiId}/*/*`,
      }),
    )
  } catch {
    /* already permitted */
  }
}

async function putRestIntegration(
  input: RestMethodIntegrationInput,
): Promise<void> {
  const client = restClient()
  const method = input.httpMethod.toUpperCase()
  const type = input.integrationType

  if (type === 'MOCK') {
    await client.send(
      new PutIntegrationCommand({
        restApiId: input.apiId,
        resourceId: input.resourceId,
        httpMethod: method,
        type: 'MOCK',
        requestTemplates: {
          'application/json': '{"statusCode":200}',
        },
      }),
    )
    await client.send(
      new PutMethodResponseCommand({
        restApiId: input.apiId,
        resourceId: input.resourceId,
        httpMethod: method,
        statusCode: '200',
      }),
    )
    await client.send(
      new PutIntegrationResponseCommand({
        restApiId: input.apiId,
        resourceId: input.resourceId,
        httpMethod: method,
        statusCode: '200',
        selectionPattern: '',
      }),
    )
    return
  }

  if (type === 'AWS_PROXY') {
    const name = input.lambdaFunctionName?.trim()
    if (!name) throw new Error('Lambda function is required')
    const fnArn = await resolveLambdaArn(name)
    await client.send(
      new PutIntegrationCommand({
        restApiId: input.apiId,
        resourceId: input.resourceId,
        httpMethod: method,
        type: 'AWS_PROXY',
        integrationHttpMethod: 'POST',
        uri: lambdaProxyUri(fnArn),
      }),
    )
    await grantApiGatewayInvoke(input.apiId, name)
    return
  }

  const uri = input.httpUri?.trim()
  if (!uri) throw new Error('HTTP endpoint URI is required')
  const integMethod = (
    input.integrationHttpMethod?.trim() || method
  ).toUpperCase()
  await client.send(
    new PutIntegrationCommand({
      restApiId: input.apiId,
      resourceId: input.resourceId,
      httpMethod: method,
      type: 'HTTP_PROXY',
      integrationHttpMethod: integMethod,
      uri,
    }),
  )
}

/** NONE auth + chosen LocalEmu integration (MOCK / Lambda proxy / HTTP proxy). */
export async function createRestMethod(
  input: RestMethodIntegrationInput,
): Promise<void> {
  const client = restClient()
  const method = input.httpMethod.toUpperCase()
  await client.send(
    new PutMethodCommand({
      restApiId: input.apiId,
      resourceId: input.resourceId,
      httpMethod: method,
      authorizationType: 'NONE',
    }),
  )
  await putRestIntegration({ ...input, httpMethod: method })
}

/** Replace integration on an existing method (edit path). */
export async function updateRestMethodIntegration(
  input: RestMethodIntegrationInput,
): Promise<void> {
  await putRestIntegration(input)
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
  if (
    authType === 'REQUEST' ||
    authType === 'TOKEN' ||
    authType === 'COGNITO_USER_POOLS'
  ) {
    const name = authorizers.find((a) => a.id === authorizerId)?.name
    return name ? `${authType} · ${name}` : authType
  }
  return authType
}

function resourceNodesOf(resources: Resource[]): RestResourceNode[] {
  return [...resources]
    .filter((r): r is Resource & { id: string } => Boolean(r.id))
    .map((r) => ({ id: r.id, path: r.path ?? '/' }))
    .sort((a, b) => a.path.localeCompare(b.path))
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
    const resourceId = r.id ?? ''
    const methods = r.resourceMethods
    if (!methods || Object.keys(methods).length === 0) {
      rows.push({
        resourceId,
        path,
        method: '—',
        integration: '—',
        integrationType: null,
        integrationUri: null,
        authorization: '—',
      })
      continue
    }
    for (const [method, detail] of Object.entries(methods)) {
      const integ = detail.methodIntegration
      rows.push({
        resourceId,
        path,
        method,
        integration: integrationLabel(integ?.type, integ?.uri),
        integrationType: integ?.type ?? null,
        integrationUri: integ?.uri ?? null,
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
  const items = resourcesOut.items ?? []
  return {
    api,
    resources: flattenResources(items, authorizers),
    resourceNodes: resourceNodesOf(items),
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
