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

test.describe('Step Functions state machines UI (#175)', () => {
  test('lists a seeded state machine', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-sfn-ui-${ts}`
    const role = `e2e-sfn-role-${ts}`
    const trust =
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    const def =
      '{"Comment":"e2e","StartAt":"Hi","States":{"Hi":{"Type":"Pass","Result":{"ok":true},"End":true}}}'

    let smArn = ''
    try {
      aws([
        'iam',
        'create-role',
        '--role-name',
        role,
        '--assume-role-policy-document',
        trust,
      ])
      const roleArn = aws([
        'iam',
        'get-role',
        '--role-name',
        role,
        '--query',
        'Role.Arn',
        '--output',
        'text',
      ]).trim()
      smArn = aws([
        'stepfunctions',
        'create-state-machine',
        '--name',
        name,
        '--definition',
        def,
        '--role-arn',
        roleArn,
        '--query',
        'stateMachineArn',
        '--output',
        'text',
      ]).trim()

      await page.goto('/stepfunctions')
      await expect(
        page.getByRole('heading', { level: 1, name: 'State machines' }),
      ).toBeVisible()
      await expect(
        page.getByTestId('sfn-state-machines-table'),
      ).toBeVisible()
      await expect(
        page.getByRole('button', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('button', { name: 'Create state machine' }),
      ).toBeDisabled()
      await expect(
        page.getByRole('button', { name: 'Create state machine' }),
      ).toHaveAttribute('title', 'To implement')
    } finally {
      if (smArn) {
        try {
          aws([
            'stepfunctions',
            'delete-state-machine',
            '--state-machine-arn',
            smArn,
          ])
        } catch {
          /* ignore */
        }
      }
      try {
        aws(['iam', 'delete-role', '--role-name', role])
      } catch {
        /* ignore */
      }
    }
  })
})
