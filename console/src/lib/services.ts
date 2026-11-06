export type AppId =
  | 's3'
  | 'iam'
  | 'lambda'
  | 'logs'
  | 'apigw'
  | 'cfn'
  | 'transfer'
  | 'rds'
  | 'ecs'
  | 'ec2'
  | 'sfn'
  | 'secretsmanager'
  | 'kinesis'
  | 'sqs'
  | 'kms'
  | 'sns'
  | 'dynamodb'

export type ServiceDef = {
  id: AppId
  abbr: string
  name: string
  desc: string
  to: string
}

export const SERVICES: ServiceDef[] = [
  { id: 's3', abbr: 'S3', name: 'S3', desc: 'Scalable Storage in the Cloud', to: '/' },
  { id: 'iam', abbr: 'IAM', name: 'IAM', desc: 'Manage access to stackwrangler resources', to: '/iam' },
  { id: 'lambda', abbr: 'λ', name: 'Lambda', desc: 'Run code without thinking about servers', to: '/lambda' },
  { id: 'apigw', abbr: 'API', name: 'API Gateway', desc: 'Build, deploy and manage APIs', to: '/apigateway' },
  { id: 'logs', abbr: 'CW', name: 'CloudWatch', desc: 'Monitor logs and metrics', to: '/logs' },
  { id: 'cfn', abbr: 'CFN', name: 'CloudFormation', desc: 'Model and provision resources', to: '/cloudformation' },
  { id: 'transfer', abbr: 'TF', name: 'Transfer Family', desc: 'Managed SFTP, FTPS and FTP', to: '/transfer' },
  { id: 'rds', abbr: 'RDS', name: 'RDS', desc: 'Managed relational databases', to: '/rds' },
  { id: 'ecs', abbr: 'ECS', name: 'Elastic Container Service', desc: 'Run containerized applications', to: '/ecs' },
  { id: 'ec2', abbr: 'EC2', name: 'EC2', desc: 'Virtual servers in the cloud', to: '/ec2' },
  {
    id: 'sfn',
    abbr: 'SFN',
    name: 'Step Functions',
    desc: 'Coordinate distributed applications',
    to: '/stepfunctions',
  },
  {
    id: 'secretsmanager',
    abbr: 'SM',
    name: 'Secrets Manager',
    desc: 'Manage secrets and credentials',
    to: '/secretsmanager',
  },
  {
    id: 'kinesis',
    abbr: 'KIN',
    name: 'Kinesis',
    desc: 'Real-time data streams',
    to: '/kinesis',
  },
  {
    id: 'sqs',
    abbr: 'SQS',
    name: 'SQS',
    desc: 'Managed message queues',
    to: '/sqs',
  },
  {
    id: 'kms',
    abbr: 'KMS',
    name: 'Key Management Service',
    desc: 'Create and manage encryption keys',
    to: '/kms',
  },
  {
    id: 'sns',
    abbr: 'SNS',
    name: 'SNS',
    desc: 'Pub/sub notifications',
    to: '/sns',
  },
  {
    id: 'dynamodb',
    abbr: 'DDB',
    name: 'DynamoDB',
    desc: 'NoSQL key-value and document store',
    to: '/dynamodb',
  },
]

export function currentApp(pathname: string): AppId {
  if (pathname.startsWith('/iam')) return 'iam'
  if (pathname.startsWith('/lambda')) return 'lambda'
  if (pathname.startsWith('/logs')) return 'logs'
  if (pathname.startsWith('/apigateway')) return 'apigw'
  if (pathname.startsWith('/cloudformation')) return 'cfn'
  if (pathname.startsWith('/transfer')) return 'transfer'
  if (pathname.startsWith('/rds')) return 'rds'
  if (pathname.startsWith('/ecs')) return 'ecs'
  if (pathname.startsWith('/ec2')) return 'ec2'
  if (pathname.startsWith('/stepfunctions')) return 'sfn'
  if (pathname.startsWith('/secretsmanager')) return 'secretsmanager'
  if (pathname.startsWith('/kinesis')) return 'kinesis'
  if (pathname.startsWith('/sqs')) return 'sqs'
  if (pathname.startsWith('/kms')) return 'kms'
  if (pathname.startsWith('/sns')) return 'sns'
  if (pathname.startsWith('/dynamodb')) return 'dynamodb'
  return 's3'
}

export type SearchItem = {
  type: 'Service' | 'Feature'
  label: string
  to: string
}

export const SEARCH_INDEX: SearchItem[] = [
  ...SERVICES.flatMap((s): SearchItem[] => {
    const items: SearchItem[] = [{ type: 'Service', label: s.name, to: s.to }]
    if (s.abbr.toLowerCase() !== s.name.toLowerCase()) {
      items.push({ type: 'Service', label: s.abbr, to: s.to })
    }
    return items
  }),
  { type: 'Feature', label: 'General purpose buckets', to: '/' },
  { type: 'Feature', label: 'Directory buckets', to: '/directory-buckets' },
  { type: 'Feature', label: 'Table buckets', to: '/table-buckets' },
  { type: 'Feature', label: 'Vector buckets', to: '/vector-buckets' },
  { type: 'Feature', label: 'Access Points', to: '/access-points' },
  { type: 'Feature', label: 'Access Points for FSx', to: '/access-points-fsx' },
  { type: 'Feature', label: 'Access Grants', to: '/access-grants' },
  { type: 'Feature', label: 'Storage Lens', to: '/storage-lens' },
  { type: 'Feature', label: 'Batch Operations', to: '/batch-operations' },
  { type: 'Feature', label: 'IAM Access Analyzer', to: '/access-analyzer' },
  { type: 'Feature', label: 'File systems', to: '/file-systems' },
  { type: 'Feature', label: 'Account and organization settings', to: '/account-settings' },
  { type: 'Feature', label: 'AWS Marketplace for S3', to: '/marketplace' },
  { type: 'Feature', label: 'IAM Users', to: '/iam' },
  { type: 'Feature', label: 'Lambda Functions', to: '/lambda' },
  { type: 'Feature', label: 'State machines', to: '/stepfunctions' },
  { type: 'Feature', label: 'Secrets', to: '/secretsmanager' },
  { type: 'Service', label: 'Kinesis Data Streams', to: '/kinesis' },
  { type: 'Feature', label: 'Data streams', to: '/kinesis' },
  { type: 'Service', label: 'Simple Queue Service', to: '/sqs' },
  { type: 'Feature', label: 'Queues', to: '/sqs' },
  { type: 'Feature', label: 'Customer managed keys', to: '/kms' },
  { type: 'Service', label: 'Simple Notification Service', to: '/sns' },
  { type: 'Feature', label: 'Topics', to: '/sns' },
  { type: 'Feature', label: 'Tables', to: '/dynamodb' },
  { type: 'Feature', label: 'Log groups', to: '/logs' },
  { type: 'Feature', label: 'HTTP APIs', to: '/apigateway' },
  { type: 'Feature', label: 'REST APIs', to: '/apigateway/rest-apis' },
  { type: 'Feature', label: 'Stacks', to: '/cloudformation' },
  { type: 'Feature', label: 'Create stack', to: '/cloudformation/create' },
  { type: 'Feature', label: 'StackSets', to: '/cloudformation/stacksets' },
  { type: 'Feature', label: 'Transfer servers', to: '/transfer' },
  { type: 'Feature', label: 'Databases', to: '/rds' },
  { type: 'Feature', label: 'Create database', to: '/rds/create' },
  { type: 'Feature', label: 'Clusters', to: '/ecs' },
  { type: 'Feature', label: 'Instances', to: '/ec2' },
  { type: 'Feature', label: 'VPCs', to: '/ec2/vpcs' },
  { type: 'Feature', label: 'Load balancers', to: '/ec2/load-balancers' },
]

const CRUMBS: Record<string, string> = {
  '/': 'Buckets',
  '/directory-buckets': 'Buckets',
  '/table-buckets': 'Table buckets',
  '/vector-buckets': 'Vector buckets',
  '/file-systems': 'File systems',
  '/access-points': 'Access Points',
  '/access-points-fsx': 'Access Points for FSx',
  '/access-grants': 'Access Grants',
  '/access-analyzer': 'IAM Access Analyzer',
  '/storage-lens': 'Storage Lens',
  '/batch-operations': 'Batch Operations',
  '/account-settings': 'Account and organization settings',
  '/marketplace': 'AWS Marketplace for S3',
  '/iam': 'Users',
  '/lambda': 'Functions',
  '/lambda/create': 'Create function',
  '/logs': 'Log groups',
  '/stepfunctions': 'State machines',
  '/secretsmanager': 'Secrets',
  '/kinesis': 'Data streams',
  '/sqs': 'Queues',
  '/kms': 'Customer managed keys',
  '/sns': 'Topics',
  '/dynamodb': 'Tables',
  '/apigateway': 'HTTP APIs',
  '/apigateway/rest-apis': 'REST APIs',
  '/cloudformation': 'Stacks',
  '/cloudformation/create': 'Create stack',
  '/cloudformation/stacksets': 'StackSets',
  '/transfer': 'Servers',
  '/rds': 'Databases',
  '/rds/create': 'Create database',
  '/ecs': 'Clusters',
  '/ecs/create': 'Create cluster',
  '/ec2': 'Instances',
  '/ec2/vpcs': 'Your VPCs',
  '/ec2/load-balancers': 'Load balancers',
}

export function crumbFor(pathname: string): string {
  const exact = CRUMBS[pathname]
  if (exact) return exact
  const bucket = /^\/buckets\/([^/]+)/.exec(pathname)
  if (bucket?.[1]) return decodeURIComponent(bucket[1])
  const parts = pathname.split('/').filter(Boolean)
  const last = parts[parts.length - 1]
  return last ? decodeURIComponent(last) : 'Buckets'
}

export function formatAccountId(id: string): string {
  const digits = id.replace(/\D/g, '')
  if (digits.length !== 12) return id
  return `${digits.slice(0, 4)}-${digits.slice(4, 8)}-${digits.slice(8)}`
}
