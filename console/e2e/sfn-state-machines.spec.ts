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

test.describe('Step Functions state machines UI (#175 / #533)', () => {
  test('lists a seeded state machine and opens detail', async ({ page }) => {
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
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('link', { name: 'Create state machine' }),
      ).toBeVisible()

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(
        new RegExp(`/stepfunctions/state-machines/${name}$`),
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('sfn-tab-details')).toBeVisible()
      await page.getByTestId('sfn-tab-definition').click()
      await expect(page.getByTestId('sfn-definition')).toContainText('Pass')
      await page.getByTestId('sfn-tab-executions').click()
      await expect(page.getByTestId('sfn-executions-table')).toBeVisible()
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

  test('creates a Pass Standard state machine in the console', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-sfn-create-${ts}`
    let smArn = ''

    try {
      await page.goto('/stepfunctions')
      await page.getByRole('link', { name: 'Create state machine' }).click()
      await expect(page).toHaveURL(/\/stepfunctions\/create$/)
      await expect(
        page.getByRole('heading', { level: 1, name: 'Create state machine' }),
      ).toBeVisible()
      await page.getByTestId('sfn-create-name').fill(name)
      await page.getByTestId('sfn-create-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/stepfunctions/state-machines/${name}$`),
        { timeout: 20000 },
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByText('Standard').first()).toBeVisible()
      await page.getByTestId('sfn-tab-definition').click()
      await expect(page.getByTestId('sfn-definition')).toContainText(
        'HelloWorld',
      )

      smArn = aws([
        'stepfunctions',
        'list-state-machines',
        '--query',
        `stateMachines[?name==\`${name}\`].stateMachineArn`,
        '--output',
        'text',
      ]).trim()
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
    }
  })
})
