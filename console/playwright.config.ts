import { defineConfig, devices } from '@playwright/test'

const baseURL =
  process.env.STACKWRANGLER_CONSOLE_URL ||
  process.env.AWSBOX_CONSOLE_URL ||
  'http://127.0.0.1:3000'

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: process.env.CI ? [['github'], ['list']] : 'list',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      testIgnore: '**/e2e/docs/**',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'docs-capture',
      testMatch: '**/e2e/docs/**/*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1280, height: 800 },
      },
    },
  ],
  webServer: {
    command: 'yarn dev --host 127.0.0.1 --port 3000',
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})

