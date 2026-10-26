export async function handler(event) {
  return {
    statusCode: 200,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ok: true,
      action: 'token-admin',
      table: process.env.TABLE_NAME || '',
      authorizer: (event.requestContext && event.requestContext.authorizer) || {},
    }),
  }
}
