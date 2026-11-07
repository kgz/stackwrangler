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

test.describe('CloudFormation StackSets + nested chrome (#95)', () => {
  test('StackSets list loads (empty OK) with dead Create', async ({ page }) => {
    await page.goto('/cloudformation/stacksets')
    await expect(
      page.getByRole('heading', { level: 1, name: 'StackSets' }),
    ).toBeVisible()
    await expect(page.getByTestId('cfn-stacksets-table')).toBeVisible()
    await expect(
      page.getByRole('button', { name: 'Create StackSet' }),
    ).toBeDisabled()
    await expect(
      page.getByRole('button', { name: 'Create StackSet' }),
    ).toHaveAttribute('title', 'To implement')
    await expect(page.getByRole('button', { name: 'Delete' })).toBeDisabled()
    await expect(page.getByRole('link', { name: 'StackSets' })).toBeVisible()
  })

  test('stack detail shows Parent / Root rows', async ({ page }) => {
    const ts = Date.now()
    const stack = `e2e-cfn-nested-ui-${ts}`
    const template = JSON.stringify({
      AWSTemplateFormatVersion: '2010-09-09',
      Description: 'e2e nested chrome',
      Resources: {
        Topic: { Type: 'AWS::SNS::Topic' },
      },
    })
    try {
      aws([
        'cloudformation',
        'create-stack',
        '--stack-name',
        stack,
        '--template-body',
        template,
      ])
      for (let i = 0; i < 40; i++) {
        const st = aws([
          'cloudformation',
          'describe-stacks',
          '--stack-name',
          stack,
          '--query',
          'Stacks[0].StackStatus',
          '--output',
          'text',
        ]).trim()
        if (st.endsWith('_COMPLETE') || st.endsWith('_FAILED')) break
        await new Promise((r) => setTimeout(r, 1500))
      }

      await page.goto(`/cloudformation/stacks/${encodeURIComponent(stack)}`)
      await expect(page.getByRole('heading', { name: stack })).toBeVisible({
        timeout: 15000,
      })
      await expect(page.getByText('Parent stack')).toBeVisible()
      await expect(page.getByText('Root stack')).toBeVisible()
    } finally {
      try {
        aws(['cloudformation', 'delete-stack', '--stack-name', stack])
      } catch {
        /* ignore */
      }
    }
  })
})
