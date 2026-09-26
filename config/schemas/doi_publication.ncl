# SPDX-License-Identifier: MPL-2.0
# Nickel >=1.8. Contract for the flat RESERVED attestation only. Apply with:
# let C = import "doi_publication.ncl" in (import "publication.ncl") | C
# Status/receipt lifecycle is doi_publication.schema.json; Julia additionally
# verifies remote state, file bytes, identifiers and explicit confirmation.
let Matching = fun regex => std.contract.from_predicate (fun v =>
  std.is_string v && std.string.is_match regex v) in
let Hash = Matching "^[0-9a-f]{64}$" in
let UUID = Matching "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" in
let Optional = fun C => std.contract.any_of [std.contract.from_predicate (fun v => v == null), C] in
let Environment = Matching "^(sandbox|production)$" in
let Kind = Matching "^(configuration|analysis_result)$" in
let Release = Matching "^https://github[.]com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+/releases/tag/[A-Za-z0-9_.~+/-]+$" in
let Project = Matching "^https://github[.]com/(users|orgs)/[A-Za-z0-9][A-Za-z0-9-]*/projects/[1-9][0-9]*$" in
std.contract.all_of [
  {
    schema_version | Matching "^1[.]0[.]0$",
    publication_id | Hash,
    environment | Environment,
    state | Matching "^reserved$" | doc "A reservation is not a published, citable DOI.",
    deposition_id | Matching "^[1-9][0-9]{0,17}$",
    doi | Matching "^10[.](5072|5281)/zenodo[.][1-9][0-9]*$",
    kind | Kind,
    config_id | UUID,
    config_hash | Hash,
    config_file_sha256 | Hash,
    result_id | Optional UUID,
    result_hash | Optional Hash,
    result_file_sha256 | Optional Hash,
    dangerous | Bool | doc "Scientific DANGER warnings remain in the original bundle.",
    github_release_url | Optional Release,
    github_project_url | Optional Project,
  },
  std.contract.from_predicate (fun value =>
    (value.doi == ((if value.environment == "sandbox" then "10.5072/zenodo." else "10.5281/zenodo.") ++ value.deposition_id)) &&
    (if value.kind == "configuration" then
      value.result_id == null && value.result_hash == null && value.result_file_sha256 == null
    else
      value.result_id != null && value.result_hash != null && value.result_file_sha256 != null)),
]
