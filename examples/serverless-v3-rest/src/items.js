export async function handler(event) {
  return {
    statusCode: 200,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ok: true,
      path: event.path || event.rawPath || '',
      stage: process.env.STAGE || '',
      app: process.env.APP_NAME || '',
    }),
  }
}
// redeploy 1793001133
