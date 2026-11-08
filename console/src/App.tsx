import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { Shell } from './components/Shell'
import { BucketObjectsPage } from './pages/BucketObjectsPage'
import { BucketsPage } from './pages/BucketsPage'
import { ApiGatewayPage } from './pages/ApiGatewayPage'
import { ApiGatewayRestApiDetailPage } from './pages/ApiGatewayRestApiDetailPage'
import { ApiGatewayRestApisPage } from './pages/ApiGatewayRestApisPage'
import { IamUsersPage } from './pages/IamUsersPage'
import { LambdaCreateFunctionPage } from './pages/LambdaCreateFunctionPage'
import { LambdaFunctionDetailPage } from './pages/LambdaFunctionDetailPage'
import { LambdaFunctionsPage } from './pages/LambdaFunctionsPage'
import { LogsPage } from './pages/LogsPage'
import { StepFunctionsDetailPage } from './pages/StepFunctionsDetailPage'
import { StepFunctionsPage } from './pages/StepFunctionsPage'
import { SecretsPage } from './pages/SecretsPage'
import { KinesisStreamsPage } from './pages/KinesisStreamsPage'
import { SqsQueuesPage } from './pages/SqsQueuesPage'
import { EventBridgeRulesPage } from './pages/EventBridgeRulesPage'
import { EventBridgeBusesPage } from './pages/EventBridgeBusesPage'
import { KmsKeysPage } from './pages/KmsKeysPage'
import { SnsTopicsPage } from './pages/SnsTopicsPage'
import { DynamoDBTablesPage } from './pages/DynamoDBTablesPage'
import { AccessAnalyzerPage } from './pages/AccessAnalyzerPage'
import { AccountSettingsPage } from './pages/AccountSettingsPage'
import { FileSystemsPage } from './pages/FileSystemsPage'
import { MarketplacePage } from './pages/MarketplacePage'
import { AccessManagementPage } from './pages/AccessManagementPage'
import { SpecialtyBucketsPage } from './pages/SpecialtyBucketsPage'
import { StorageInsightsPage } from './pages/StorageInsightsPage'
import { CloudFormationCreateStackPage } from './pages/CloudFormationCreateStackPage'
import { CloudFormationStacksPage } from './pages/CloudFormationStacksPage'
import { CloudFormationUpdateStackPage } from './pages/CloudFormationUpdateStackPage'
import { CloudFormationCreateChangeSetPage } from './pages/CloudFormationCreateChangeSetPage'
import { CloudFormationChangeSetDetailPage } from './pages/CloudFormationChangeSetDetailPage'
import { CloudFormationStackSetsPage } from './pages/CloudFormationStackSetsPage'
import { TransferServersPage } from './pages/TransferServersPage'
import { RdsCreateDatabasePage } from './pages/RdsCreateDatabasePage'
import { RdsInstancesPage } from './pages/RdsInstancesPage'
import {
  EcsClustersPage,
  EcsCreateClusterPage,
} from './pages/EcsClustersPage'
import { Ec2InstancesPage } from './pages/Ec2InstancesPage'
import { LoadBalancersPage } from './pages/LoadBalancersPage'
import { VpcsPage } from './pages/VpcsPage'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Shell />}>
          <Route index element={<BucketsPage />} />
          <Route path="buckets/:name" element={<BucketObjectsPage />} />
          <Route path="iam" element={<IamUsersPage />} />
          <Route path="lambda" element={<LambdaFunctionsPage />} />
          <Route path="lambda/create" element={<LambdaCreateFunctionPage />} />
          <Route
            path="lambda/functions/:name"
            element={<LambdaFunctionDetailPage />}
          />
          <Route path="logs" element={<LogsPage />} />
          <Route path="stepfunctions" element={<StepFunctionsPage />} />
          <Route
            path="stepfunctions/state-machines/:name"
            element={<StepFunctionsDetailPage />}
          />
          <Route path="secretsmanager" element={<SecretsPage />} />
          <Route path="kinesis" element={<KinesisStreamsPage />} />
          <Route path="sqs" element={<SqsQueuesPage />} />
          <Route path="events" element={<EventBridgeRulesPage />} />
          <Route path="events/buses" element={<EventBridgeBusesPage />} />
          <Route path="kms" element={<KmsKeysPage />} />
          <Route path="sns" element={<SnsTopicsPage />} />
          <Route path="dynamodb" element={<DynamoDBTablesPage />} />
          <Route path="apigateway" element={<ApiGatewayPage />} />
          <Route
            path="apigateway/rest-apis"
            element={<ApiGatewayRestApisPage />}
          />
          <Route
            path="apigateway/rest-apis/:apiId"
            element={<ApiGatewayRestApiDetailPage />}
          />
          <Route path="cloudformation" element={<CloudFormationStacksPage />} />
          <Route
            path="cloudformation/create"
            element={<CloudFormationCreateStackPage />}
          />
          <Route
            path="cloudformation/stacks/:name/update"
            element={<CloudFormationUpdateStackPage />}
          />
          <Route
            path="cloudformation/stacks/:name/change-sets/create"
            element={<CloudFormationCreateChangeSetPage />}
          />
          <Route
            path="cloudformation/stacks/:name/change-sets/:changeSetName"
            element={<CloudFormationChangeSetDetailPage />}
          />
          <Route
            path="cloudformation/stacks/:name"
            element={<CloudFormationStacksPage />}
          />
          <Route
            path="cloudformation/stacksets"
            element={<CloudFormationStackSetsPage />}
          />
          <Route path="transfer" element={<TransferServersPage />} />
          <Route
            path="transfer/servers/:serverId"
            element={<TransferServersPage />}
          />
          <Route path="rds" element={<RdsInstancesPage />} />
          <Route path="rds/create" element={<RdsCreateDatabasePage />} />
          <Route path="rds/databases/:id" element={<RdsInstancesPage />} />
          <Route path="ecs" element={<EcsClustersPage />} />
          <Route path="ecs/create" element={<EcsCreateClusterPage />} />
          <Route path="ecs/clusters/:name" element={<EcsClustersPage />} />
          <Route
            path="ecs/clusters/:name/tasks/:taskId"
            element={<EcsClustersPage />}
          />
          <Route path="ec2" element={<Ec2InstancesPage />} />
          <Route
            path="ec2/instances/:instanceId"
            element={<Ec2InstancesPage />}
          />
          <Route path="ec2/vpcs" element={<VpcsPage />} />
          <Route path="ec2/vpcs/:vpcId" element={<VpcsPage />} />
          <Route path="ec2/load-balancers" element={<LoadBalancersPage />} />
          <Route path="directory-buckets" element={<SpecialtyBucketsPage />} />
          <Route path="table-buckets" element={<SpecialtyBucketsPage />} />
          <Route path="vector-buckets" element={<SpecialtyBucketsPage />} />
          <Route path="file-systems" element={<FileSystemsPage />} />
          <Route path="access-points" element={<AccessManagementPage />} />
          <Route path="access-points-fsx" element={<AccessManagementPage />} />
          <Route path="access-grants" element={<AccessManagementPage />} />
          <Route path="access-analyzer" element={<AccessAnalyzerPage />} />
          <Route path="storage-lens" element={<StorageInsightsPage />} />
          <Route path="batch-operations" element={<StorageInsightsPage />} />
          <Route path="account-settings" element={<AccountSettingsPage />} />
          <Route path="marketplace" element={<MarketplacePage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
