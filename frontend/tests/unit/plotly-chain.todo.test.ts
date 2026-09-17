// Filed TODO scaffolds (machine-enumerated, per the constraint: "if
// something is untestable, document why and file a TODO").
//
// These five modules cannot even be IMPORTED under a DOM-less bun runtime:
// they pull in plotly.js (directly or via PlotlyChart), whose minified
// bundle touches `document` at module-initialisation time
// (node_modules/plotly.js-dist-min/plotly.min.js). Establishing a DOM
// harness (happy-dom/jsdom) or driving these through the playwright e2e
// lane is a later decision — tracking:
//   TODO(tests/e2e-lane): plotly-chain modules need a DOM-capable lane
//   (decision at Prompt 5: remain queued for the e2e lane; see
//   docs/testing/coverage.md §"Not tested" and
//   docs/testing/infrastructure.md §"What the scaffolds deliberately
//   do not test")
import { test } from 'bun:test'

test.todo('PlotlyChart: module loads and renders against a DOM lane')
test.todo('ComparisonPanel: module loads and renders against a DOM lane')
test.todo('ChartEditorInner: module loads and renders against a DOM lane')
test.todo('AnnotationPanel: module loads and renders against a DOM lane')
test.todo('RunView: module loads and renders against a DOM lane')
