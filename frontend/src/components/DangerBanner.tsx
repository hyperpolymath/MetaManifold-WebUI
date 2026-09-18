// SPDX-License-Identifier: AGPL-3.0-only
import type { AnalysisConfig } from '../types/analysis_config'
import { isDangerous, DANGER_ACK_TOKEN } from '../types/analysis_config'

interface DangerBannerProps {
  config: AnalysisConfig
  onAcknowledge?: (token: string) => void
}

export function DangerBanner({ config, onAcknowledge }: DangerBannerProps) {
  if (!isDangerous(config)) return null

  const reasons: string[] = []
  if (config.correction.allow_no_correction) {
    reasons.push(`BH correction disabled (method=${config.correction.method}). This will inflate false discoveries in high-dimensional data.`)
  }
  if (config.advanced.zero_handling === 'refuse') {
    reasons.push(`zero_handling='refuse' will cause log(0) or biased zero handling.`)
  }
  if (config.normalization.method === 'rarefy' && config.method === 'nb_glm') {
    reasons.push(`Rarefaction for NB_GLM discards data and reduces power; size_factors preferred (McMurdie & Holmes 2014).`)
  }
  if (config.advanced.min_samples_per_group < 3) {
    reasons.push(`min_samples_per_group=${config.advanced.min_samples_per_group} <3: variance estimation will be unstable.`)
  }

  return (
    <div style={{
      background: '#ffebee',
      border: '3px solid #c62828',
      borderRadius: 8,
      padding: 16,
      marginBottom: 16,
      fontFamily: 'monospace',
      whiteSpace: 'pre-wrap',
      color: '#b71c1c',
    }}>
      <div style={{ fontWeight: 800, fontSize: 16, marginBottom: 8, textAlign: 'center' }}>
        ⚠️  DANGER — SCIENTIFICALLY RISKY CONFIGURATION DETECTED  ⚠️
      </div>
      <div style={{ marginBottom: 12 }}>
        You have enabled overrides that weaken statistical rigor:
        <ul style={{ margin: '8px 0', paddingLeft: 20 }}>
          {reasons.map((r, i) => <li key={i}>{r}</li>)}
        </ul>
      </div>
      <div style={{ fontSize: 12, marginBottom: 8 }}>
        This configuration will be:
        <br />• Logged in provenance with full user identity and timestamp
        <br />• Bannered in every figure and DOI bundle
        <br />• Flagged in the GitHub Project board as 'needs-review'
      </div>
      <div style={{ marginTop: 12, padding: 8, background: '#fff3e0', borderRadius: 4 }}>
        <strong>If you are sure, you must acknowledge with token:</strong>
        <br />
        <code style={{ background: '#ffccbc', padding: '2px 6px', borderRadius: 4, userSelect: 'all' }}>
          {DANGER_ACK_TOKEN}
        </code>
        <br />
        <span style={{ fontSize: 11 }}>Paste this token into the acknowledgment field below.</span>
      </div>

      {onAcknowledge && (
        <div style={{ marginTop: 12 }}>
          <input
            type="text"
            placeholder="Paste acknowledgment token here"
            onChange={e => {
              if (e.target.value === DANGER_ACK_TOKEN) {
                onAcknowledge(e.target.value)
              }
            }}
            style={{
              width: '100%',
              padding: '8px',
              border: '1px solid #c62828',
              borderRadius: 4,
              fontFamily: 'monospace',
            }}
          />
        </div>
      )}

      <div style={{ marginTop: 12, fontSize: 11, color: '#666' }}>
        Consider: Is there a safer alternative? Consult context-sensitive help.
        See: hyperpolymath/standards JSON + Nickel + DEED schemes.
      </div>
    </div>
  )
}
