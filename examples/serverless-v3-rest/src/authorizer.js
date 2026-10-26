export async function handler(event) {
  const header =
    event.authorizationToken ||
    (event.headers && (event.headers.Authorization || event.headers.authorization)) ||
    ''
  const token = String(header).replace(/^Bearer\s+/i, '').trim()
  const allow = token === 'good'
  return {
    principalId: allow ? 'user' : 'deny',
    policyDocument: {
      Version: '2012-10-17',
      Statement: [
        {
          Action: 'execute-api:Invoke',
          Effect: allow ? 'Allow' : 'Deny',
          Resource: event.methodArn || event.routeArn || '*',
        },
      ],
    },
    context: { tenant: 'demo-tenant' },
  }
}
