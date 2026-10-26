// Echoes the REST (v1) proxy event fields a handler usually reads.
exports.handler = async (event) => ({
  statusCode: 200,
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    path: event.path,
    method: event.httpMethod,
    query: event.queryStringParameters,
    authorizer: (event.requestContext || {}).authorizer || null,
  }),
});
