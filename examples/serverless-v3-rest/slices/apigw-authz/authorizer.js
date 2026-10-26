// REQUEST authorizer: allows "Bearer good", denies anything else.
// API Gateway keeps the header's original case, so check both spellings.
exports.handler = async (event) => {
  const h = event.headers || {};
  const allow = (h.Authorization || h.authorization) === "Bearer good";
  return {
    principalId: "demo-user",
    policyDocument: {
      Version: "2012-10-17",
      Statement: [{ Action: "execute-api:Invoke", Effect: allow ? "Allow" : "Deny", Resource: event.methodArn }],
    },
    context: { tenant: "demo-tenant" },
  };
};
