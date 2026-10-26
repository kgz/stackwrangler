// Allows every caller and hands the bearer token to API Gateway as the usage plan key
// (apiKeySource AUTHORIZER).
exports.handler = async (event) => {
  const h = event.headers || {};
  const token = String(h.Authorization || h.authorization || "").replace(/^Bearer /, "");
  return {
    principalId: "client",
    policyDocument: {
      Version: "2012-10-17",
      Statement: [{ Action: "execute-api:Invoke", Effect: "Allow", Resource: event.methodArn }],
    },
    usageIdentifierKey: token,
  };
};
