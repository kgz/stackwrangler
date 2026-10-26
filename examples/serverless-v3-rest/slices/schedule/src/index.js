const { DynamoDBClient, ScanCommand, DeleteItemCommand } = require("@aws-sdk/client-dynamodb");

exports.handler = async () => {
  console.log("sweep-tick");
  const table = process.env.TABLE_NAME;
  if (!table) return { swept: 0 };
  const ddb = new DynamoDBClient({});
  const now = String(Math.floor(Date.now() / 1000));
  const found = await ddb.send(
    new ScanCommand({
      TableName: table,
      FilterExpression: "expiresAt < :now",
      ExpressionAttributeValues: { ":now": { N: now } },
    }),
  );
  for (const item of found.Items ?? []) {
    await ddb.send(new DeleteItemCommand({ TableName: table, Key: { id: item.id } }));
  }
  return { swept: (found.Items ?? []).length };
};
