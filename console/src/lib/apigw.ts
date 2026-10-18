import {
  ApiGatewayV2Client,
  CreateApiCommand,
  CreateIntegrationCommand,
  CreateRouteCommand,
  CreateStageCommand,
  GetApisCommand,
  type Api,
} from '@aws-sdk/client-apigatewayv2'
import {
  AddPermissionCommand,
  GetFunctionCommand,
  LambdaClient,
} from '@aws-sdk/client-lambda'
import { config } from './config'
import { emuCreds } from './emu'

function apigwClient(): ApiGatewayV2Client {
  return new ApiGatewayV2Client(emuCreds())
}

function lambdaClient(): LambdaClient {
  return new LambdaClient(emuCreds())
}

export async function listHttpApis(): Promise<Api[]> {
  const out = await apigwClient().send(new GetApisCommand({}))
  return out.Items ?? []
}

export type WiredApi = {
  apiId: string
  name: string
  invokeUrl: string
}

/** Create HTTP API → Lambda proxy on GET / and ANY /{proxy+} */
export async function createHttpApiForLambda(
  apiName: string,
  functionName: string,
): Promise<WiredApi> {
  const lambda = lambdaClient()
  const fn = await lambda.send(
    new GetFunctionCommand({ FunctionName: functionName }),
  )
  const fnArn = fn.Configuration?.FunctionArn
  if (!fnArn) {
    throw new Error(`Function ${functionName} has no ARN`)
  }

  const gw = apigwClient()
  const api = await gw.send(
    new CreateApiCommand({
      Name: apiName,
      ProtocolType: 'HTTP',
      CorsConfiguration: {
        AllowOrigins: ['*'],
        AllowMethods: ['*'],
        AllowHeaders: ['*'],
      },
    }),
  )
  const apiId = api.ApiId
  if (!apiId) {
    throw new Error('CreateApi returned no ApiId')
  }

  const integration = await gw.send(
    new CreateIntegrationCommand({
      ApiId: apiId,
      IntegrationType: 'AWS_PROXY',
      IntegrationUri: fnArn,
      PayloadFormatVersion: '2.0',
      IntegrationMethod: 'POST',
    }),
  )
  const integrationId = integration.IntegrationId
  if (!integrationId) {
    throw new Error('CreateIntegration returned no IntegrationId')
  }

  await gw.send(
    new CreateRouteCommand({
      ApiId: apiId,
      RouteKey: 'GET /',
      Target: `integrations/${integrationId}`,
    }),
  )
  await gw.send(
    new CreateRouteCommand({
      ApiId: apiId,
      RouteKey: 'ANY /{proxy+}',
      Target: `integrations/${integrationId}`,
    }),
  )
  await gw.send(
    new CreateStageCommand({
      ApiId: apiId,
      StageName: '$default',
      AutoDeploy: true,
    }),
  )

  try {
    await lambda.send(
      new AddPermissionCommand({
        FunctionName: functionName,
        StatementId: `apigw-${apiId}`,
        Action: 'lambda:InvokeFunction',
        Principal: 'apigateway.amazonaws.com',
        SourceArn: `arn:aws:execute-api:${config.region}:${config.accountId}:${apiId}/*/*`,
      }),
    )
  } catch {
    /* already permitted */
  }

  const invokeUrl = localInvokeUrl(apiId)
  return { apiId, name: apiName, invokeUrl }
}

/** LocalEmu HTTP API invoke path (see CreateApi log: execute-api-v2) */
export function localInvokeUrl(apiId: string): string {
  const base = config.iamEndpoint.replace(/\/$/, '')
  return `${base}/_aws/execute-api-v2/${apiId}/$default/`
}

export function browserInvokeUrl(apiId: string): string {
  if (typeof window !== 'undefined' && window.location?.origin) {
    return `${window.location.origin}/aws-iam/_aws/execute-api-v2/${apiId}/$default/`
  }
  return localInvokeUrl(apiId)
}
