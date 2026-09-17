// Type-boundary tests — hooks/useJobEvents.ts JobEventBus.
//
// Boundary under test: the job event bus is the state-transition hub between
// SSE-land and view state: `emit(job)` fans out to every subscriber and
// `subscribe(fn)` returns the unsubscribe. Tested contracts: (1) every
// listener receives the exact Job object (JobStatus is the five-state union
// from src/api/types.ts), (2) listeners added later start fresh, (3) the
// returned unsubscribe removes exactly that listener.
//
// Framework faithfulness: the bus factory itself is plain TypeScript — no
// React render needed; the hook wrapper (useJobRefetch) needs React and is
// covered at the type level + listed as an e2e-lane gap.
import { describe, test, expect } from 'bun:test'
import { createJobEventBus } from '../../src/hooks/useJobEvents'
import type { Job, JobStatus } from '../../src/api/types'

const makeJob = (id: number, status: JobStatus): Job =>
  ({ id, name: `job-${id}`, kind: 'pipeline', study: 'study-a', run: 'run-1', status }) as Job

describe('createJobEventBus — observable fan-out and removal', () => {
  test('a subscriber receives the exact Job objects emitted', () => {
    // Arrange
    const bus = createJobEventBus()
    const received: Job[] = []
    bus.subscribe((j) => received.push(j))
    const job = makeJob(7, 'complete')
    // Act
    bus.emit(job)
    // Assert: identity delivery, exactly once.
    expect(received.length).toBe(1)
    expect(received[0]).toBe(job)
  })

  test('parameterised over the full JobStatus union', () => {
    const statuses: JobStatus[] = ['queued', 'running', 'complete', 'failed', 'cancelled']
    for (const status of statuses) {
      const bus = createJobEventBus()
      let got: JobStatus | undefined
      bus.subscribe((j) => { got = j.status })
      bus.emit(makeJob(1, status))
      expect(got).toBe(status)
    }
  })

  test('all current subscribers are notified; late joiners miss history', () => {
    // Arrange
    const bus = createJobEventBus()
    const a: number[] = []
    const b: number[] = []
    bus.subscribe((j) => a.push(j.id))
    bus.emit(makeJob(1, 'running'))
    bus.subscribe((j) => b.push(j.id))
    // Act
    bus.emit(makeJob(2, 'complete'))
    // Assert: only emissions after subscription are delivered.
    expect(a).toEqual([1, 2])
    expect(b).toEqual([2])
  })

  test('the returned unsubscribe removes exactly that listener', () => {
    // Arrange
    const bus = createJobEventBus()
    const kept: number[] = []
    const dropped: number[] = []
    bus.subscribe((j) => kept.push(j.id))
    const off = bus.subscribe((j) => dropped.push(j.id))
    // Act
    off()
    bus.emit(makeJob(3, 'failed'))
    bus.emit(makeJob(4, 'cancelled'))
    // Assert
    expect(kept).toEqual([3, 4])
    expect(dropped).toEqual([])
  })

  test('emission with zero subscribers is a no-op (no throw)', () => {
    const bus = createJobEventBus()
    expect(() => bus.emit(makeJob(9, 'queued'))).not.toThrow()
  })
})
