#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Independent exact-summary reference: integer sums and reduced fractions in GNU bc.
#
# Usage: exact_summary_reference.sh INPUT.json
# Input and output counts are decimal strings; zero-total proportions are JSON null.
# bc shares no code with the Julia implementation (GMP), and this program never
# reads output from it. jq only moves labels and digit strings around; every
# sum, gcd and division is done by bc.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: exact_summary_reference.sh INPUT.json" >&2; exit 2; }
for tool in bc jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required (apt-get install $tool)" >&2; exit 2; }
done
input="$1"

# One block per summary: "L<TAB>json label", then one "F<TAB>values" line per
# feature holding that feature's value in every member column, then "E".
# Samples first, then groups in order of first appearance.
blocks() {
  jq -r '
    . as $p
    | ($p.counts | length) as $nf
    | ($p.feature_labels | length) as $nl
    | if $nf != $nl then error("counts rows do not match feature_labels") else . end
    | def block($label; $cols):
        "L\t" + ($label | @json),
        (range(0; $nf) as $i | "F\t" + ([$cols[] as $j | $p.counts[$i][$j] | tostring] | join(" "))),
        "E";
      ($p.sample_labels | length) as $ns
    | (range(0; $ns) as $j | block($p.sample_labels[$j]; [$j])),
      (if $p.groups == null then empty else
         if ($p.groups | length) != $ns then error("groups do not match sample_labels") else . end
         | ($p.groups | reduce .[] as $g ([]; if index([$g]) == null then . + [$g] else . end)) as $order
         | ($order[] as $g | block($g; [range(0; $ns) | select($p.groups[.] == $g)]))
       end)
  ' "$input"
}

# Print "total", the counts and the reduced proportions of one summary, one per
# line, from the value lists on stdin-style arguments.
summarise() {
  local -a lists=("$@")
  local program="define g(a, b) { auto t; if (a < 0) a = -a; if (b < 0) b = -b; while (b != 0) { t = a % b; a = b; b = t }; return (a) }
t = 0
"
  local i=0 value list
  for list in "${lists[@]}"; do
    program+="c[$i] = 0"
    for value in $list; do
      [[ "$value" =~ ^-?[0-9]+$ ]] || { echo "not a decimal integer: $value" >&2; return 2; }
      program+=" + ($value)"
    done
    program+=$'\n'"t = t + c[$i]"$'\n'
    i=$((i + 1))
  done
  program+="t
"
  for ((k = 0; k < i; k++)); do program+="c[$k]"$'\n'; done
  for ((k = 0; k < i; k++)); do
    program+="if (t == 0) { \"null"$'\n'"\"; \"null"$'\n'"\" } else { d = g(c[$k], t); n = c[$k] / d; m = t / d; if (m < 0) { n = -n; m = -m }; n; m }"$'\n'
  done
  # Each feature prints its numerator and denominator on two lines, or null twice.
  printf '%s\nquit\n' "$program" | BC_LINE_LENGTH=0 bc
}

emit() {
  local label="$1"; shift
  local -a lists=("$@")
  local n=${#lists[@]} out
  out="$(summarise "${lists[@]}")" || exit 2
  local -a lines
  mapfile -t lines <<<"$out"
  local total="${lines[0]}" counts="" props="" k pos
  for ((k = 0; k < n; k++)); do
    counts+="${counts:+,}\"${lines[1 + k]}\""
  done
  pos=$((1 + n))
  for ((k = 0; k < n; k++)); do
    if [[ "${lines[pos]}" == null ]]; then
      props+="${props:+,}null"
    else
      props+="${props:+,}\"${lines[pos]}/${lines[pos + 1]}\""
    fi
    pos=$((pos + 2))
  done
  printf '{"label":%s,"total":"%s","counts":[%s],"proportions":[%s]}\n' "$label" "$total" "$counts" "$props"
}

samples=() groups=()
section=samples
label="" ; lists=()
n_samples="$(jq '.sample_labels | length' "$input")"
count=0
# Captured with a checked assignment, so a failure in blocks stops the script
# instead of reading as empty input.
block_lines="$(blocks)"
while IFS=$'\t' read -r tag rest; do
  case "$tag" in
    L) label="$rest"; lists=() ;;
    F) lists+=("$rest") ;;
    E)
      line="$(emit "$label" "${lists[@]}")"
      if (( count < n_samples )); then samples+=("$line"); else groups+=("$line"); fi
      count=$((count + 1)) ;;
    *) ;;
  esac
done <<<"$block_lines"

join() { local IFS=,; echo "$*"; }
printf '{"samples":[%s],"groups":[%s]}\n' "$(join "${samples[@]}")" "$(join "${groups[@]}")" | jq -ac .
