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

function deleteRuleQuiet(name: string, bus = 'default') {
  try {
    aws([
      'events',
      'remove-targets',
      '--rule',
      name,
      '--event-bus-name',
      bus,
      '--ids',
      '1',
    ])
  } catch {
    /* ignore */
  }
  try {
    aws(['events', 'delete-rule', '--name', name, '--event-bus-name', bus])
  } catch {
    /* ignore */
  }
}

function deleteBusQuiet(name: string) {
  try {
    aws(['events', 'delete-event-bus', '--name', name])
  } catch {
    /* ignore */
  }
}

test.describe('EventBridge rules UI (#173 / #552 / #630)', () => {
  test('lists a seeded rule and opens detail', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-events-ui-${ts}`
    try {
      aws([
        'events',
        'put-rule',
        '--name',
        name,
        '--event-pattern',
        '{"source":["awsbox.e2e"]}',
        '--state',
        'ENABLED',
      ])
      aws([
        'events',
        'put-targets',
        '--rule',
        name,
        '--targets',
        'Id=1,Arn=arn:aws:lambda:us-east-1:000000000000:function:e2e-events-ui',
      ])

      await page.goto('/events')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Rules' }),
      ).toBeVisible()
      await expect(page.getByTestId('eventbridge-rules-table')).toBeVisible()
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await expect(
        page.getByRole('link', { name: 'Create rule' }),
      ).toBeVisible()
      await expect(page.getByTestId('events-delete')).toBeDisabled()
      await expect(page.getByTestId('events-delete')).toHaveAttribute(
        'title',
        'Select a row',
      )

      await page.getByRole('link', { name, exact: true }).click()
      await expect(page).toHaveURL(
        new RegExp(`/events/rules/${name}\\?bus=default$`),
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('events-tab-details')).toBeVisible()
      await expect(page.getByTestId('events-rule-pattern')).toContainText(
        'awsbox.e2e',
      )
      await page.getByTestId('events-tab-targets').click()
      await expect(page.getByTestId('events-targets-table')).toBeVisible()
      await expect(page.getByText('e2e-events-ui').first()).toBeVisible()
    } finally {
      deleteRuleQuiet(name)
    }
  })

  test('edits a rule, puts and removes a target, then deletes', async ({
    page,
  }) => {
    const ts = Date.now()
    const name = `e2e-events-mutate-${ts}`
    const targetArn =
      'arn:aws:lambda:us-east-1:000000000000:function:e2e-events-mutate'
    let created = false

    try {
      aws([
        'events',
        'put-rule',
        '--name',
        name,
        '--event-pattern',
        '{"source":["awsbox.e2e.mutate"]}',
        '--state',
        'ENABLED',
      ])
      created = true

      await page.goto(
        `/events/rules/${encodeURIComponent(name)}?bus=default`,
      )
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible({ timeout: 15000 })

      await page.getByTestId('events-detail-edit').click()
      await expect(page).toHaveURL(
        new RegExp(`/events/rules/${name}/edit\\?bus=default$`),
      )
      await page.getByTestId('events-edit-rule-description').fill('edited')
      await page
        .getByTestId('events-edit-rule-pattern')
        .fill('{"source":["awsbox.e2e.edited"]}')
      await page.getByTestId('events-edit-rule-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/events/rules/${name}\\?bus=default$`),
        { timeout: 20000 },
      )
      await expect(page.getByTestId('events-rule-pattern')).toContainText(
        'awsbox.e2e.edited',
      )
      await expect(page.getByText('edited').first()).toBeVisible()

      await page.getByTestId('events-tab-targets').click()
      await page.getByTestId('events-add-target').click()
      await expect(page.getByTestId('events-add-target-modal')).toBeVisible()
      await page.getByTestId('events-add-target-id').fill('1')
      await page.getByTestId('events-add-target-arn').fill(targetArn)
      await page.getByTestId('events-add-target-submit').click()
      await expect(page.getByText(targetArn).first()).toBeVisible({
        timeout: 15000,
      })

      await page.getByRole('radio', { name: 'Select 1' }).check()
      await page.getByTestId('events-remove-target').click()
      await page.getByTestId('events-confirm-remove-target').click()
      await expect(page.getByText('No targets')).toBeVisible({
        timeout: 15000,
      })

      await page.getByTestId('events-detail-delete').click()
      await page.getByTestId('events-confirm-delete').click()
      await expect(page).toHaveURL(/\/events$/, { timeout: 20000 })
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toHaveCount(0)
      created = false
    } finally {
      if (created) deleteRuleQuiet(name)
    }
  })

  test('deletes a selected rule from the list', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-events-del-${ts}`
    let created = false

    try {
      aws([
        'events',
        'put-rule',
        '--name',
        name,
        '--event-pattern',
        '{"source":["awsbox.e2e.del"]}',
        '--state',
        'ENABLED',
      ])
      created = true

      await page.goto('/events')
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toBeVisible({ timeout: 15000 })
      await page
        .getByRole('row')
        .filter({ has: page.getByRole('link', { name, exact: true }) })
        .click()
      await expect(page.getByTestId('events-delete')).toBeEnabled()
      await page.getByTestId('events-delete').click()
      await page.getByTestId('events-confirm-delete').click()
      await expect(
        page.getByRole('link', { name, exact: true }),
      ).toHaveCount(0, { timeout: 15000 })
      created = false
    } finally {
      if (created) deleteRuleQuiet(name)
    }
  })

  test('creates an event-pattern rule from the console', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-events-create-${ts}`
    let created = false

    try {
      await page.goto('/events')
      await page.getByRole('link', { name: 'Create rule' }).click()
      await expect(page).toHaveURL(/\/events\/create$/)
      await expect(
        page.getByRole('heading', { level: 1, name: 'Create rule' }),
      ).toBeVisible()
      await page.getByTestId('events-create-rule-name').fill(name)
      await page.getByTestId('events-create-rule-type-pattern').check()
      await page
        .getByTestId('events-create-rule-pattern')
        .fill('{"source":["awsbox.e2e.create"]}')
      await page.getByTestId('events-create-rule-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/events/rules/${name}\\?bus=default$`),
        { timeout: 20000 },
      )
      created = true
      await expect(
        page.getByRole('heading', { level: 1, name }),
      ).toBeVisible()
      await expect(page.getByTestId('events-rule-pattern')).toContainText(
        'awsbox.e2e.create',
      )
    } finally {
      if (created) deleteRuleQuiet(name)
    }
  })

  test('creates a schedule rule from the console', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-events-sched-${ts}`
    let created = false

    try {
      await page.goto('/events/create')
      await page.getByTestId('events-create-rule-name').fill(name)
      await page.getByTestId('events-create-rule-type-schedule').check()
      await page
        .getByTestId('events-create-rule-schedule')
        .fill('rate(10 minutes)')
      await page.getByTestId('events-create-rule-submit').click()
      await expect(page).toHaveURL(
        new RegExp(`/events/rules/${name}\\?bus=default$`),
        { timeout: 20000 },
      )
      created = true
      await expect(page.getByText('rate(10 minutes)').first()).toBeVisible()
    } finally {
      if (created) deleteRuleQuiet(name)
    }
  })

  test('disables schedule when event bus is not default', async ({ page }) => {
    const ts = Date.now()
    const bus = `e2e-bus-sched-guard-${ts}`
    try {
      aws(['events', 'create-event-bus', '--name', bus])
      await page.goto('/events/create')
      await expect(
        page.getByTestId('events-create-rule-type-schedule'),
      ).toBeEnabled({ timeout: 15000 })
      await page.getByTestId('events-create-rule-bus').selectOption(bus)
      await expect(
        page.getByTestId('events-create-rule-type-schedule'),
      ).toBeDisabled()
      await expect(
        page.getByTestId('events-create-rule-type-schedule'),
      ).toHaveAttribute(
        'title',
        'Schedule rules require the default event bus',
      )
      await expect(
        page.getByTestId('events-create-rule-type-pattern'),
      ).toBeChecked()
    } finally {
      deleteBusQuiet(bus)
    }
  })
})

test.describe('EventBridge event buses UI (#173 / #552)', () => {
  test('lists default bus and a seeded custom bus', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-bus-ui-${ts}`
    try {
      aws(['events', 'create-event-bus', '--name', name])

      await page.goto('/events/buses')
      await expect(
        page.getByRole('heading', { level: 1, name: 'Event buses' }),
      ).toBeVisible()
      await expect(page.getByTestId('eventbridge-buses-table')).toBeVisible()
      await expect(page.getByText('default', { exact: true }).first()).toBeVisible(
        { timeout: 15000 },
      )
      await expect(page.getByText(name, { exact: true })).toBeVisible({
        timeout: 15000,
      })
      await expect(
        page.getByRole('link', { name: 'Create event bus' }),
      ).toBeVisible()
    } finally {
      deleteBusQuiet(name)
    }
  })

  test('creates an event bus from the console', async ({ page }) => {
    const ts = Date.now()
    const name = `e2e-bus-create-${ts}`
    let created = false

    try {
      await page.goto('/events/buses')
      await page.getByRole('link', { name: 'Create event bus' }).click()
      await expect(page).toHaveURL(/\/events\/buses\/create$/)
      await page.getByTestId('events-create-bus-name').fill(name)
      await page
        .getByTestId('events-create-bus-description')
        .fill('e2e custom bus')
      await page.getByTestId('events-create-bus-submit').click()
      await expect(page).toHaveURL(/\/events\/buses$/, { timeout: 20000 })
      created = true
      await expect(page.getByText(name, { exact: true })).toBeVisible({
        timeout: 15000,
      })
      await expect(page.getByText('e2e custom bus')).toBeVisible()
    } finally {
      if (created) deleteBusQuiet(name)
    }
  })
})
