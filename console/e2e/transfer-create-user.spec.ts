import { expect, test } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
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
  ).trim()
}

function tryAws(args: string[]) {
  try {
    aws(args)
  } catch {
    /* ignore */
  }
}

test.describe('Transfer create user + import SSH key (#321)', () => {
  const ts = Date.now()
  const roleName = `e2e-xfer-role-${ts}`
  const userName = `e2e-xfer-user-${ts}`
  let serverId = ''
  let roleArn = ''
  const pubKey = `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI${randomBytes(16).toString('base64url').slice(0, 32)} e2e@stackwrangler`

  test.beforeAll(() => {
    aws([
      'iam',
      'create-role',
      '--role-name',
      roleName,
      '--assume-role-policy-document',
      JSON.stringify({
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Principal: { Service: 'transfer.amazonaws.com' },
            Action: 'sts:AssumeRole',
          },
        ],
      }),
    ])
    roleArn = aws([
      'iam',
      'get-role',
      '--role-name',
      roleName,
      '--query',
      'Role.Arn',
      '--output',
      'text',
    ])
    serverId = aws([
      'transfer',
      'create-server',
      '--protocols',
      'SFTP',
      '--identity-provider-type',
      'SERVICE_MANAGED',
      '--query',
      'ServerId',
      '--output',
      'text',
    ])
  })

  test.afterAll(() => {
    if (serverId && userName) {
      tryAws([
        'transfer',
        'delete-user',
        '--server-id',
        serverId,
        '--user-name',
        userName,
      ])
    }
    if (serverId) {
      tryAws(['transfer', 'delete-server', '--server-id', serverId])
    }
    tryAws(['iam', 'delete-role', '--role-name', roleName])
  })

  test('create user with SSH key from server detail', async ({ page }) => {
    await page.goto(`/transfer/servers/${encodeURIComponent(serverId)}`)
    await expect(
      page.getByRole('heading', { level: 1, name: serverId }),
    ).toBeVisible()
    await expect(page.getByTestId('transfer-add-user')).toBeVisible()
    await expect(page.getByTestId('transfer-add-ssh-key')).toBeVisible()
    await expect(page.getByTestId('transfer-delete-user')).toBeDisabled()
    await expect(page.getByTestId('transfer-delete-user')).toHaveAttribute(
      'title',
      'To implement',
    )

    await page.getByTestId('transfer-add-user').click()
    await expect(page).toHaveURL(
      new RegExp(`/transfer/servers/${serverId}/users/create$`),
    )
    await page.getByTestId('transfer-create-user-name').fill(userName)
    await page.getByTestId('transfer-create-role').fill(roleArn)
    await page.getByTestId('transfer-create-home').fill('/e2e-home')
    await page.getByTestId('transfer-create-ssh-key').fill(pubKey)
    await page.getByTestId('transfer-create-user-submit').click()
    await expect(page).toHaveURL(
      new RegExp(`/transfer/servers/${serverId}/users/${userName}$`),
      { timeout: 20000 },
    )
    await expect(
      page.getByRole('heading', { level: 1, name: userName }),
    ).toBeVisible()
    const keys = page.getByTestId('transfer-ssh-keys-table')
    await expect(keys).toContainText(pubKey.slice(0, 24), { timeout: 15000 })

    const described = aws([
      'transfer',
      'describe-user',
      '--server-id',
      serverId,
      '--user-name',
      userName,
      '--output',
      'json',
    ])
    expect(described).toContain('SshPublicKey')
    expect(described).toContain(pubKey.split(' ')[0] ?? 'ssh-ed25519')
  })

  test('import additional SSH key from UI', async ({ page }) => {
    const secondKey = `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI${randomBytes(16).toString('base64url').slice(0, 32)} e2e2@stackwrangler`
    await page.goto(
      `/transfer/servers/${encodeURIComponent(serverId)}/users/import-ssh-key?user=${encodeURIComponent(userName)}`,
    )
    await expect(
      page.getByRole('heading', { level: 1, name: 'Import SSH public key' }),
    ).toBeVisible()
    await page.getByTestId('transfer-import-ssh-key').fill(secondKey)
    await page.getByTestId('transfer-import-submit').click()
    await expect(page).toHaveURL(
      new RegExp(`/transfer/servers/${serverId}/users/${userName}$`),
      { timeout: 20000 },
    )
    const keys = page.getByTestId('transfer-ssh-keys-table')
    await expect(keys).toContainText(secondKey.slice(0, 24), { timeout: 15000 })
  })
})
