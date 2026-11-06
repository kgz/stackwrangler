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

test.describe('CloudFormation create stack UI', () => {
  test('paste template, create, poll to complete', async ({ page }) => {
    test.setTimeout(180_000)
    const ts = Date.now()
    const stack = `e2e-cfn-create-${ts}`
    const bucket = `e2e-cfn-create-b-${ts}`

    const template = JSON.stringify(
      {
        AWSTemplateFormatVersion: '2010-09-09',
        Description: 'e2e console create stack',
        Resources: {
          DemoBucket: {
            Type: 'AWS::S3::Bucket',
            Properties: { BucketName: bucket },
          },
        },
      },
      null,
      2,
    )

    await page.goto('/cloudformation')
    await expect(
      page.getByRole('heading', { name: /^Stacks \(/ }),
    ).toBeVisible()
    await page.locator('.aws-main a.btn-primary', { hasText: 'Create stack' }).click()
    await expect(
      page.getByRole('heading', { name: 'Create stack', exact: true }),
    ).toBeVisible()

    await page.getByTestId('cfn-create-name').fill(stack)
    await page.getByTestId('cfn-create-body').fill(template)
    await page.getByTestId('cfn-create-submit').click()

    await expect(page.getByRole('heading', { name: stack })).toBeVisible({
      timeout: 30_000,
    })

    await expect
      .poll(
        async () => {
          const badge = page.locator('.aws-status').first()
          return (await badge.textContent())?.trim() ?? ''
        },
        { timeout: 120_000 },
      )
      .toMatch(/CREATE_COMPLETE|CREATE_FAILED/)

    await expect(page.locator('.aws-status').first()).toHaveText(
      'CREATE_COMPLETE',
      { timeout: 5_000 },
    )

    aws(['cloudformation', 'delete-stack', '--stack-name', stack])
  })
})
