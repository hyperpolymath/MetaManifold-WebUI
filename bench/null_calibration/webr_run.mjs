#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Sandbox-only driver: run calibration.R / summarise.R under WebR (R in
// WebAssembly) when no native R is available. The R code executed is the
// bench's own, unmodified; MASS comes from sourcing MASS's pure-R negbin.R
// (glm.nb makes no compiled calls), which calibration.R detects and records
// in its provenance output. Prefer native Rscript with the renv.lock pin
// whenever it exists - it is faster and carries glmGamPoi/edgeR.
//
// One-time setup (outside the repo, so no repo lockfile changes):
//   mkdir ~/webr-probe && cd ~/webr-probe && npm init -y && npm i webr@0.6.0
//   git clone https://github.com/cran/MASS.git mass-src
//   git -C mass-src checkout b6a2274   # MASS 7.3-65, the renv.lock pin
//
// Run, from the repo root:
//   WEBR_PATH=~/webr-probe/node_modules/webr \
//   node bench/null_calibration/webr_run.mjs \
//     --mass-r ~/webr-probe/mass-src/R/negbin.R \
//     --script calibration -- --n-per=4 --sims=200 --tests=wald_ml,lrt
// Files land in bench/null_calibration/results/raw (override with
// --host-out). For summarise, existing raw CSVs in --host-out are mounted
// in first, and the summary CSVs are copied back to --host-summary-out
// (default bench/null_calibration/results).

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const sep = argv.indexOf('--');
const driverArgs = sep === -1 ? argv : argv.slice(0, sep);
const rArgs = sep === -1 ? [] : argv.slice(sep + 1);

function opt(name, fallback) {
  const hit = driverArgs.find((a) => a.startsWith(`${name}=`));
  if (hit) return hit.slice(name.length + 1);
  const i = driverArgs.indexOf(name);
  return i === -1 ? fallback : driverArgs[i + 1];
}

const script = opt('--script', 'calibration');
const massR = opt('--mass-r', '');
const hostOut = resolve(opt('--host-out', join(here, 'results', 'raw')));
const hostSummaryOut = resolve(opt('--host-summary-out', join(here, 'results')));
const webrPath = process.env.WEBR_PATH || 'webr';
// WEBR_PATH may name the package directory or its ESM entry directly.
const webrEntry = webrPath === 'webr' ? 'webr'
  : pathToFileURL(resolve(webrPath.endsWith('.mjs') ? webrPath : join(webrPath, 'dist', 'webr.mjs'))).href;
const { WebR } = await import(webrEntry);

// No stdout/stderr callbacks here: under Node the WebR worker cannot clone
// function options, and the defaults already stream R output to this
// process's stdout/stderr line by line.
const webR = new WebR({ interactive: false });
await webR.init();
// Record the executor in every provenance file the R code writes. Native
// Rscript runs of calibration.R record R.version.string instead.
const executor = `webR ${webR.version || "0.6.0"}`;
await webR.evalRVoid(`Sys.setenv(NB_EXECUTOR = ${JSON.stringify(executor)})`);

const put = async (vfsPath, hostPath) => {
  const dir = vfsPath.slice(0, vfsPath.lastIndexOf('/'));
  if (dir) await webR.evalRVoid(`dir.create("${dir}", recursive = TRUE, showWarnings = FALSE)`);
  await webR.FS.writeFile(vfsPath, readFileSync(hostPath));
};

await put('/work/calibration.R', join(here, 'calibration.R'));
await put('/work/summarise.R', join(here, 'summarise.R'));
await put('/work/differential.jl', join(here, '..', '..', 'src', 'analysis', 'differential.jl'));
if (massR) await put('/work/negbin.R', resolve(massR.replace(/^~/, process.env.HOME || '')));

// Mount any existing raw results so summarise (and resumed calibration
// cells appending to the same CSV) see them.
if (existsSync(hostOut)) {
  for (const f of readdirSync(hostOut)) {
    if (/\.(csv|txt)$/.test(f)) await put(`/work/results/raw/${f}`, join(hostOut, f));
  }
}

const benchArgs = [...rArgs.filter((a) => !a.startsWith('--differential-jl=') && !a.startsWith('--out=') && !a.startsWith('--results=')),
  '--differential-jl=/work/differential.jl',
  // calibration.R writes raw cells to --out; summarise.R writes summaries to
  // --out. They are different directories.
  script === 'summarise' ? '--out=/work/results' : '--out=/work/results/raw',
  '--results=/work/results/raw'];
const quote = (s) => `'${s.replace(/'/g, "'\\''")}'`;
await webR.evalRVoid(`Sys.setenv(NB_CALIB_ARGS = ${quote(benchArgs.join(' '))})`);
if (massR) await webR.evalRVoid('source("/work/negbin.R")');
await webR.evalRVoid('setwd("/work")');
await webR.evalRVoid(`source("/work/${script}.R")`);

mkdirSync(hostOut, { recursive: true });
mkdirSync(hostSummaryOut, { recursive: true });
for (const [vfsDir, hostDir] of [['/work/results/raw', hostOut], ['/work/results', hostSummaryOut]]) {
  const listing = await (await webR.evalR(
    `list.files("${vfsDir}", pattern = "\\\\.(csv|txt)$")`)).toJs();
  for (const name of listing.values) {
    if (vfsDir.endsWith('/raw') === false && name.startsWith('pvalues_')) continue;
    const bytes = await webR.FS.readFile(`${vfsDir}/${name}`);
    writeFileSync(join(hostDir, name), bytes);
    console.log(`[webr_run] ${name} -> ${join(hostDir, name)}`);
  }
}
await webR.close();
process.exit(0);
