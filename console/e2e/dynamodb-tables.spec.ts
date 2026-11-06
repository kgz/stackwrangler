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

function waitActive(name: string) {
  for (let i = 0; i < 60; i++) {
    try {
      const st = aws([
        'dynamodb',
        'describe-table',
        '--table-name',
        name,
        '--query',
        'Table.TableStatus',
        '--output',
        'text',
      ]).trim()
      if (st === 'ACTIVE') return
    } catch {
      /* creating */
    }
    execFileSync('sleep', ['1'])
  }
  throw new Error(`table not ACTIVE: ${name}`)
}

test.describe('DynamoDB tables UI (#174)', () => {
  test('lists a seeded table', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-ddb-ui-${ts}`
    try {
      aws([
        'dynamodb',
        'create-table',
        '--table-name',
        name,
        '--attribute-definitions',
        'AttributeName=pk,AttributeType=S',
        '--key-schema',
        'AttributeName=pk,KeyType=HASH',
        '--billing-mode',
        'PAY_PER_REQUEST',
      ])
      waitActive(name)

      await page.goto('/dynamodb')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Tables' }),
      ).toBeVisible()
      await expect(page.getByTestId('dynamodb-tables-table')).toBeVisible()
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create table' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create table' }),
      ).toHaveAttribute('title', 'To implement')
      await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
      await expect(page.getByRole('button', { name: 'Delete' })).toHaveAttribute(
        'title',
        'Select a row',
      )
    } finally {
      try {
        aws(['dynamodb', 'delete-table', '--table-name', name])
      } catch {
        /* ignore */
      }
    }
  })
})
