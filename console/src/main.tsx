import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import '../../design/awsbox/tokens.css'
import '../../design/awsbox-console/assets/fonts.css'
import './index.css'
import './styles/awsbox-console.css'

const root = document.getElementById('root')
if (!root) {
  throw new Error('missing #root')
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
