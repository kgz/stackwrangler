import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { Shell } from './components/Shell'
import { BucketObjectsPage } from './pages/BucketObjectsPage'
import { BucketsPage } from './pages/BucketsPage'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Shell />}>
          <Route index element={<BucketsPage />} />
          <Route path="buckets/:name" element={<BucketObjectsPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
