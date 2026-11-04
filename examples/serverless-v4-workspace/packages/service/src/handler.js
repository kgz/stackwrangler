'use strict'

const { greet } = require('@awsbox/ws-shared')

exports.handler = async () => {
  const name = process.env.GREET_NAME || 'workspace'
  return {
    statusCode: 200,
    body: JSON.stringify({ message: greet(name) }),
  }
}
