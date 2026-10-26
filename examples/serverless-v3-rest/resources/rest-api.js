'use strict'

/**
 * CFN fragment: AWS::ApiGateway::RestApi with OpenAPI Body (#184 shape).
 * Serverless also creates an http-event API; this resource proves Body import.
 */
module.exports = () => ({
  Resources: {
    OpenApiRestApi: {
      Type: 'AWS::ApiGateway::RestApi',
      Properties: {
        Name: 'awsbox-rest-openapi',
        Body: {
          openapi: '3.0.1',
          info: {
            title: 'awsbox-rest-openapi',
            version: '1.0.0',
          },
          paths: {
            '/public/ping': {
              get: {
                responses: {
                  '200': {
                    description: 'ok',
                    content: {
                      'application/json': {
                        schema: { type: 'object' },
                      },
                    },
                  },
                },
                'x-amazon-apigateway-integration': {
                  type: 'mock',
                  requestTemplates: {
                    'application/json': '{"statusCode":200}',
                  },
                  responses: {
                    default: {
                      statusCode: '200',
                      responseTemplates: {
                        'application/json': '{"ok":true,"source":"openapi-body"}',
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    OpenApiDeployment: {
      Type: 'AWS::ApiGateway::Deployment',
      DependsOn: ['OpenApiRestApi'],
      Properties: {
        RestApiId: { Ref: 'OpenApiRestApi' },
        StageName: 'local',
      },
    },
  },
})
