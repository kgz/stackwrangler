import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { Shell } from './components/Shell'
import { BucketObjectsPage } from './pages/BucketObjectsPage'
import { BucketsPage } from './pages/BucketsPage'
import { ApiGatewayPage } from './pages/ApiGatewayPage'
import { IamUsersPage } from './pages/IamUsersPage'
import { LambdaFunctionsPage } from './pages/LambdaFunctionsPage'
import { LogsPage } from './pages/LogsPage'
import { PlaceholderPage } from './pages/PlaceholderPage'
import { SpecialtyBucketsPage } from './pages/SpecialtyBucketsPage'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Shell />}>
          <Route index element={<BucketsPage />} />
          <Route path="buckets/:name" element={<BucketObjectsPage />} />
          <Route path="iam" element={<IamUsersPage />} />
          <Route path="lambda" element={<LambdaFunctionsPage />} />
          <Route path="logs" element={<LogsPage />} />
          <Route path="apigateway" element={<ApiGatewayPage />} />
          <Route path="directory-buckets" element={<SpecialtyBucketsPage />} />
          <Route path="table-buckets" element={<SpecialtyBucketsPage />} />
          <Route path="vector-buckets" element={<SpecialtyBucketsPage />} />
          <Route path="file-systems" element={<PlaceholderPage />} />
          <Route path="access-points" element={<PlaceholderPage />} />
          <Route path="access-points-fsx" element={<PlaceholderPage />} />
          <Route path="access-grants" element={<PlaceholderPage />} />
          <Route path="access-analyzer" element={<PlaceholderPage />} />
          <Route path="storage-lens" element={<PlaceholderPage />} />
          <Route path="batch-operations" element={<PlaceholderPage />} />
          <Route path="account-settings" element={<PlaceholderPage />} />
          <Route path="marketplace" element={<PlaceholderPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
