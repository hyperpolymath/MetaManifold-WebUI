# Analysis roadmap: occupancy and zero processes

**Updated: 2026-10-22.** This is the repository-side status summary for the
occupancy work. The GitHub Wiki roadmap still needs a synchronized update; see
[follow-up issue #205](https://github.com/hyperpolymath/MetaManifold-WebUI/issues/205).

## Available now

- `nb_glm`, `clr_welch`, `multinomial`, `dirichlet_multinomial`, `ancom_bc`,
  `aldex2`, and `songbird` remain available differential methods.
- `zinb` and `hurdle_nb` are available in the differential-abundance config and
  UI. They report the count effect and zero/occurrence effect and test group
  effects jointly. The UI surfaces model cautions; BH adjustment remains on.
- `MetaManifold.Differential.fit_occupancy` fits repeated-visit Boolean
  detection histories (sites × visits × taxa), with group occupancy ψ and a
  common detection probability p. This is a low-level estimator only.

## Not available as a workflow yet

Occupancy cannot yet be selected in AnalysisConfig or run through the regular
analysis endpoint. The estimator does not accept detection covariates/formulas,
primer or batch effects, or random effects; it refuses single-visit histories.
The ZINB/hurdle models do not yet have user-defined component formulas, model
selection diagnostics, or full scale benchmarks. These constraints and the
closure/destructive-sampling caveat are detailed in
[Occupancy model notes](docs/occupancy-models.md).

## Remaining work

Issue [#205](https://github.com/hyperpolymath/MetaManifold-WebUI/issues/205)
tracks first-class repeated-detection input and configuration, detection and
zero formulas, identifiability validation, diagnostics/reference comparisons,
simulation recovery, benchmarks, provenance/schema completion, and updates to
the Wiki and user/developer roadmaps. Do not describe the lower-level fitter as
a complete occupancy workflow until those acceptance criteria pass.

Issue [#18](https://github.com/hyperpolymath/MetaManifold-WebUI/issues/18)
records the originating feature request and the first implementation slice.
