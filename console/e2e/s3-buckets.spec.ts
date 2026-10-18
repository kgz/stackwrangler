import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from '@playwright/test'

const profile = process.env.AWSBOX_PROFILE || 'local'

function aws(args: string[]): string {
  return execFileSync('aws', ['--profile', profile, ...args], {
    encoding: 'utf8',
  }).trim()
}

function putText(bucket: string, key: string, body: string): void {
  const path = join(tmpdir(), `awsbox-${Date.now()}-${key}`)
  writeFileSync(path, body)
  aws(['s3', 'cp', path, `s3://${bucket}/${key}`])
}

test.describe('S3 general purpose buckets (UI + CLI)', () => {
  const bucket = `e2e-ui-${Date.now()}`

  test.afterAll(() => {
    try {
      aws(['s3', 'rb', `s3://${bucket}`, '--force'])
    } catch {
      try {
        aws(['s3api', 'delete-bucket', '--bucket', bucket])
      } catch {
        // gone already
      }
    }
  })

  test('lists buckets from the live S3 API', async ({ page }) => {
    aws(['s3', 'mb', `s3://${bucket}`])

    await page.goto('/')
    await expect(
      page.getByRole('heading', { name: 'Buckets', exact: true }),
    ).toBeVisible()
    await page.getByPlaceholder('Find buckets by name').fill(bucket)
    await expect(page.getByRole('link', { name: bucket })).toBeVisible()
  })

  test('creates a bucket in the UI and CLI can see it', async ({ page }) => {
    const name = `e2e-create-${Date.now()}`

    await page.goto('/')
    await page.getByRole('button', { name: 'Create bucket' }).first().click()
    await page.getByLabel('Bucket name').fill(name)
    await page.getByRole('button', { name: 'Create bucket' }).last().click()

    await page.getByPlaceholder('Find buckets by name').fill(name)
    await expect(page.getByRole('link', { name })).toBeVisible()

    const listed = aws(['s3', 'ls'])
    expect(listed).toContain(name)

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('uploads an object in the UI; CLI can download it', async ({ page }) => {
    const name = `e2e-obj-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await expect(page.getByRole('heading', { name })).toBeVisible()

    const fileChooserPromise = page.waitForEvent('filechooser')
    await page.getByRole('button', { name: 'Upload' }).click()
    const chooser = await fileChooserPromise
    await chooser.setFiles({
      name: 'e2e-hello.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('hello from playwright'),
    })

    await expect(page.getByText('e2e-hello.txt')).toBeVisible()

    const body = aws([
      's3',
      'cp',
      `s3://${name}/e2e-hello.txt`,
      '-',
    ])
    expect(body).toContain('hello from playwright')

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('sidebar placeholder for directory buckets', async ({ page }) => {
    await page.goto('/directory-buckets')
    await expect(
      page.getByRole('heading', { name: 'Directory buckets' }),
    ).toBeVisible()
    await expect(page.getByText('Not available on local stack')).toBeVisible()
  })

  test('empties a bucket in the UI; CLI sees no objects', async ({ page }) => {
    const name = `e2e-empty-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'a.txt', 'a')
    putText(name, 'b.txt', 'b')

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await expect(page.getByText('a.txt')).toBeVisible()
    await page.getByRole('button', { name: 'Empty' }).click()
    await page.getByRole('button', { name: 'Empty', exact: true }).last().click()
    await expect(page.getByText('No objects')).toBeVisible()

    const listed = aws(['s3', 'ls', `s3://${name}/`])
    expect(listed).toBe('')

    aws(['s3', 'rb', `s3://${name}`, '--force'])
  })

  test('deletes a bucket in the UI; CLI no longer lists it', async ({ page }) => {
    const name = `e2e-del-${Date.now()}`
    aws(['s3', 'mb', `s3://${name}`])
    putText(name, 'x.txt', 'x')

    await page.goto(`/buckets/${encodeURIComponent(name)}`)
    await page.getByRole('button', { name: 'Delete' }).click()
    await page.getByRole('button', { name: 'Delete bucket' }).click()
    await expect(
      page.getByRole('heading', { name: 'Buckets', exact: true }),
    ).toBeVisible()

    const listed = aws(['s3', 'ls'])
    expect(listed).not.toContain(name)
  })
})
