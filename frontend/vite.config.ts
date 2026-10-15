import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    outDir:      '../web/dist',
    emptyOutDir: true,
    sourcemap:   false,
    rollupOptions: {
      output: {
        // Vite 8 (rolldown) accepts manualChunks only as a function; the
        // object form it replaces listed plotly.js-dist-min by package name.
        manualChunks: (id: string) =>
          id.includes('plotly.js-dist-min') ? 'plotly' : undefined,
      },
    },
  },
  server: {
    proxy: {
      // SSE endpoint needs special handling to prevent buffering
      '/api/v1/events': {
        target: 'http://127.0.0.1:8080',
        // Disable response buffering so SSE frames stream through immediately
        configure: (proxy) => {
          proxy.on('proxyRes', (proxyRes) => {
            proxyRes.headers['cache-control'] = 'no-cache'
            proxyRes.headers['x-accel-buffering'] = 'no'
          })
        },
      },
      '/api':   'http://127.0.0.1:8080',
      '/files': 'http://127.0.0.1:8080',
    },
  },
})
