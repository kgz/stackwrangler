import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { Shell } from './components/Shell'
import { BucketObjectsPage } from './pages/BucketObjectsPage'
import { BucketsPage } from './pages/BucketsPage'
import { IamUsersPage } from './pages/IamUsersPage'
import { PlaceholderPage } from './pages/PlaceholderPage'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Shell />}>
          <Route index element={<BucketsPage />} />
          <Route path="buckets/:name" element={<BucketObjectsPage />} />
          <Route path="iam" element={<IamUsersPage />} />
          <Route path="directory-buckets" element={<PlaceholderPage />} />
          <Route path="table-buckets" element={<PlaceholderPage />} />
          <Route path="vector-buckets" element={<PlaceholderPage />} />
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
