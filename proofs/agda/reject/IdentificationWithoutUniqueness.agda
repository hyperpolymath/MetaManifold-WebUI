-- SPDX-License-Identifier: AGPL-3.0-only
-- MUST FAIL: the "Present, value unknown" preset (r = 2, |n| ≤ 1, exact view)
-- admits three admissible candidates with three different u-offsets, so
-- presence is entailed but no value is identified — this is Decision.agda's
-- present-without-identification.  A UI that reports one identified value
-- from a mere presence verdict is exactly this term, and it must not check.
-- EXPECT: fst \(fst c\) != 8
module reject.IdentificationWithoutUniqueness where

open import MetaManifold.Evidence.Prelude
open import MetaManifold.Evidence.Signed
open import MetaManifold.Evidence.Decision

present-but-unidentified : FIdentified exact 8 1 false fst
present-but-unidentified = 8 , λ c → refl
