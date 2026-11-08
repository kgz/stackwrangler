import { expect, test } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { e2eCreds } from './helpers/env'

const EP = e2eCreds.iamEndpoint
const KEY = e2eCreds.accessKey
const SECRET = e2eCreds.secretKey
const REGION = e2eCreds.region

function aws(args: string[]): string {
  return execFileSync(
    'aws',
    ['--endpoint-url', EP, '--region', REGION, ...args],
    {
      encoding: 'utf8',
      env: {
        ...process.env,
        AWS_ACCESS_KEY_ID: KEY,
        AWS_SECRET_ACCESS_KEY: SECRET,
        AWS_DEFAULT_REGION: REGION,
      },
    },
  )
}

function seedRestApi(name: string): string {
  const apiId = aws([
    'apigateway',
    'create-rest-api',
    '--name',
    name,
    '--description',
    'e2e rest console',
    '--query',
    'id',
    '--output',
    'text',
  ]).trim()

  const rootId = aws([
    'apigateway',
    'get-resources',
    '--rest-api-id',
    apiId,
    '--query',
    'items[?path==`/`].id',
    '--output',
    'text',
  ]).trim()

  const ordersId = aws([
    'apigateway',
    'create-resource',
    '--rest-api-id',
    apiId,
    '--parent-id',
    rootId,
    '--path-part',
    'orders',
    '--query',
    'id',
    '--output',
    'text',
  ]).trim()

  aws([
    'apigateway',
    'put-method',
    '--rest-api-id',
    apiId,
    '--resource-id',
    ordersId,
    '--http-method',
    'GET',
    '--authorization-type',
    'NONE',
  ])
  aws([
    'apigateway',
    'put-integration',
    '--rest-api-id',
    apiId,
    '--resource-id',
    ordersId,
    '--http-method',
    'GET',
    '--type',
    'MOCK',
    '--request-templates',
    '{"application/json":"{\\"statusCode\\":200}"}',
  ])
  aws([
    'apigateway',
    'put-method-response',
    '--rest-api-id',
    apiId,
    '--resource-id',
    ordersId,
    '--http-method',
    'GET',
    '--status-code',
    '200',
  ])
  aws([
    'apigateway',
    'put-integration-response',
    '--rest-api-id',
    apiId,
    '--resource-id',
    ordersId,
    '--http-method',
    'GET',
    '--status-code',
    '200',
    '--selection-pattern',
    '',
  ])
  aws([
    'apigateway',
    'create-authorizer',
    '--rest-api-id',
    apiId,
    '--name',
    'e2e-request-auth',
    '--type',
    'REQUEST',
    '--authorizer-uri',
    `arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:000000000000:function:e2e-rest-authorizer/invocations`,
    '--identity-source',
    'method.request.header.Authorization',
  ])
  aws([
    'apigateway',
    'create-deployment',
    '--rest-api-id',
    apiId,
    '--stage-name',
    'prod',
    '--description',
    'e2e',
  ])
  return apiId
}

test.describe('API Gateway REST APIs UI (#189 / #543)', () => {
  test('lists a seeded REST API and opens detail tabs', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-rest-ui-${ts}`
    let apiId = ''
    try {
      apiId = seedRestApi(name)

      await page.goto('/apigateway/rest-apis')
      await expect(
        page.getByRole('heading', { level: 1, name: 'APIs' }),
      ).toBeVisible()
      await expect(
        page.getByRole('link', { name: 'REST APIs' }).first(),
      ).toHaveAttribute('aria-current', 'page')
      await expect(page.getByTestId('rest-apis-table')).toBeVisible()
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(page.getByText(apiId, { exact: true })).toBeVisible()
      await expect(page.getByRole('link', { name: 'Create' })).toBeVisible()
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Refresh' })).toBeEnabled()

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(new RegExp(`/apigateway/rest-apis/${apiId}`))
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(
        page.getByRole('button', { name: 'Deploy API' }),
      ).toBeEnabled()
      await expect(
        page.getByRole('button', { name: 'Actions ▾' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Actions ▾' }),
      ).toHaveAttribute('title', 'To implement')

      await page.getByTestId('rest-api-tab-resources').click()
      await expect(page.getByTestId('rest-resources-table')).toBeVisible()
      await expect(page.getByText('/orders', { exact: true })).toBeVisible()
      await expect(page.getByText('GET', { exact: true }).first()).toBeVisible()
      await expect(
        page.getByRole('button', { name: 'Create resource' }),
      ).toBeEnabled()
      await expect(
        page.getByRole('button', { name: 'Create method' }),
      ).toBeEnabled()

      await page.getByTestId('rest-api-tab-authorizers').click()
      await expect(page.getByTestId('rest-authorizers-table')).toBeVisible()
      await expect(
        page.getByText('e2e-request-auth', { exact: true }),
      ).toBeVisible()
      await expect(
        page.getByRole('button', { name: 'Create authorizer' }),
      ).toBeDisabled()

      await page.getByTestId('rest-api-tab-stages').click()
      await expect(page.getByTestId('rest-stages-table')).toBeVisible()
      await expect(page.getByText('prod', { exact: true }).first()).toBeVisible()
      await expect(
        page.getByText(new RegExp(`/restapis/${apiId}/prod/_user_request_/`)),
      ).toBeVisible()

      await page.getByTestId('rest-api-tab-invoke').click()
      await expect(
        page.getByText(new RegExp(`/restapis/${apiId}/prod/_user_request_/`)),
      ).toBeVisible()
    } finally {
      if (apiId) {
        try {
          aws(['apigateway', 'delete-rest-api', '--rest-api-id', apiId])
        } catch {
          /* ignore */
        }
      }
    }
  })

  test('creates a REST API from the console form (#543)', async ({ page }) => {
    const name = `e2e-rest-create-${Date.now()}`
    let apiId = ''
    try {
      await page.goto('/apigateway/rest-apis')
      await page.getByRole('link', { name: 'Create' }).click()
      await expect(page).toHaveURL(/\/apigateway\/rest-apis\/create$/)
      await expect(
        page.getByRole('heading', { level: 1, name: 'Create REST API' }),
      ).toBeVisible()

      await page.getByTestId('rest-api-create-name').fill(name)
      await page
        .getByTestId('rest-api-create-description')
        .fill('console create path')
      await page.getByTestId('rest-api-create-submit').click()

      await expect(page).toHaveURL(/\/apigateway\/rest-apis\/[^/]+$/, {
        timeout: 30_000,
      })
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()

      const match = page.url().match(/\/apigateway\/rest-apis\/([^/?#]+)/)
      apiId = match ? decodeURIComponent(match[1]) : ''
      expect(apiId).toBeTruthy()

      await page.getByTestId('rest-api-tab-resources').click()
      await page.getByTestId('rest-create-resource-open').click()
      await page.getByTestId('rest-create-resource-path').fill('ping')
      await page.getByTestId('rest-create-resource-submit').click()
      await expect(page.getByText('/ping', { exact: true })).toBeVisible({
        timeout: 15_000,
      })

      await page.getByTestId('rest-create-method-open').click()
      await page.getByTestId('rest-create-method-resource').selectOption({
        label: '/ping',
      })
      await page.getByTestId('rest-create-method-http').selectOption('GET')
      await page.getByTestId('rest-create-method-submit').click()
      await expect(page.getByText('GET', { exact: true }).first()).toBeVisible({
        timeout: 15_000,
      })
      await expect(page.getByText('MOCK', { exact: true }).first()).toBeVisible()

      await page.getByTestId('rest-api-deploy-open').click()
      await page.getByTestId('rest-api-deploy-stage').fill('dev')
      await page.getByTestId('rest-api-deploy-submit').click()
      await expect(page.getByTestId('rest-stages-table')).toBeVisible()
      await expect(page.getByText('dev', { exact: true }).first()).toBeVisible({
        timeout: 15_000,
      })
    } finally {
      if (apiId) {
        try {
          aws(['apigateway', 'delete-rest-api', '--rest-api-id', apiId])
        } catch {
          /* ignore */
        }
      }
    }
  })
})
