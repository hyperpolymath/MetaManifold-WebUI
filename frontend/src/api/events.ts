import type { Job, StageStatus } from './types'
import { apiUrl } from './client'

export type SSEHandler = {
  onJobUpdate?:   (job: Job) => void
  onStageUpdate?: (ev: { study: string; run: string | null; stage: string; status: StageStatus }) => void
}

/**
 * Open a persistent SSE connection to /api/v1/events.
 * Returns a cleanup function - call it to close the connection.
 */
export function openEventStream(handlers: SSEHandler & { onConnectedChange?: (connected: boolean) => void }): () => void {
  const es = new EventSource(apiUrl('/api/v1/events'))

  // A malformed frame must not throw inside the listener: EventSource would
  // keep the stream open but the exception surfaces as an uncaught error and
  // the update is lost silently either way. Drop the bad frame instead.
  const parseFrame = (data: string): unknown => {
    try {
      return JSON.parse(data)
    } catch {
      return undefined
    }
  }

  es.addEventListener('job_update', (e: MessageEvent) => {
    const job = parseFrame(e.data)
    if (job !== undefined) handlers.onJobUpdate?.(job as Job)
  })

  es.addEventListener('stage_update', (e: MessageEvent) => {
    const ev = parseFrame(e.data)
    if (ev !== undefined) handlers.onStageUpdate?.(ev as Parameters<NonNullable<SSEHandler['onStageUpdate']>>[0])
  })

  es.onopen = () => handlers.onConnectedChange?.(true)

  es.onerror = () => {
    handlers.onConnectedChange?.(false)
    // Browser auto-reconnects; onopen will fire again when it does.
  }

  return () => es.close()
}
