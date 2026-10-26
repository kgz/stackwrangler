exports.handler = async (event) => ({
  statusCode: 200,
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ path: event.path, method: event.httpMethod }),
});
