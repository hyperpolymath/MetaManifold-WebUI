import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { loadConfig } from './api/client'
import { errorMessage } from './api/errorMessage'
import { App } from './App'
import './styles/app.css'

const root = document.getElementById('root')!

loadConfig()
  .then(() => {
    createRoot(root).render(
      <StrictMode>
        <App />
      </StrictMode>,
    )
  })
  .catch((e: unknown) => {
    // Nothing has rendered yet, so the page would otherwise stay blank.
    console.error('MetaManifold failed to start', e)
    root.textContent = `MetaManifold failed to start: ${errorMessage(e)}`
  })
