-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Machine-checked invariants for CladeCumulus cladistic aggregation,
-- epistemic world admissibility (`present_in_every_admissible_world`),
-- drag-and-drop clade reassignment validation, and branch-length
-- phylogenetic diversity (Faith's PD and Unweighted UniFrac bounds).
--
-- Theorems proved:
--
--   * `every⇒some` & `every⇒not-absent`: universal presence across a non-empty
--     case of admissible worlds entails existential presence and refutes
--     universal absence (an empty world fibre is never vacuously universal).
--   * `validateMove-sound`: accepting a clade reassignment implies non-self
--     reassignment, cycle freedom, and `presentInEvery ws target ≡ true`.
--   * `cumulative-conserves-tips`: bottom-up clade aggregation over any
--     rooted phylogenetic or taxonomic `CladeTree` equals the total read count
--     of its descendant tips without double counting or read loss.
--   * `child≤parent`: every immediate child subtree has `cumulativeCount`
--     at most its parent clade's `cumulativeCount`.
--   * `faithPD-mono` & `faithPD-bounded`: over scaled integer branch lengths,
--     Faith's Phylogenetic Diversity is monotone under tip-set inclusion
--     (`S₁ ⊆ S₂ → faithPD S₁ t ≤ faithPD S₂ t`) and bounded above by the
--     total branch length of the tree (`faithPD S t ≤ totalTreePD t`).
--   * `sharedPD≤unionPD` & `unifracNumerator≤Denominator`: shared active
--     branch length never exceeds union active branch length, and unshared
--     branch length `unionPD ∸ sharedPD` is bounded above by `unionPD`.
--
-- Not modelled here: IEEE-754 Float64 rounding, `log(1 + residual)` cloud
-- sizing, and external tree heuristics (FastTree, IQ-TREE, Neighbor-Joining).

{-# OPTIONS --safe --without-K #-}

module MetaManifold.CladeCumulus where

open import Data.Bool.Base using (Bool; true; false; not; _∧_; _∨_; if_then_else_)
open import Data.List.Base using (List; []; _∷_; _++_)
open import Data.Nat.Base using (ℕ; zero; suc; _+_; _∸_; _≤_; z≤n; s≤s)
open import Data.Product.Base using (_×_; _,_)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; sym; trans; cong; cong₂)

infixr 5 _∷ᶠ_
infix  4 _∈ᶠ_
infix  4 _⊆_

------------------------------------------------------------------------
-- Self-contained non-recursive boolean & arithmetic lemmas

private
  false≢true : ∀ {A : Set} → false ≡ true → A
  false≢true ()

  +-idʳ : ∀ m → m + zero ≡ m
  +-idʳ zero    = refl
  +-idʳ (suc m) = cong suc (+-idʳ m)

  +-assoc : ∀ m n p → (m + n) + p ≡ m + (n + p)
  +-assoc zero    _ _ = refl
  +-assoc (suc m) n p = cong suc (+-assoc m n p)

  ≤-refl : ∀ m → m ≤ m
  ≤-refl zero    = z≤n
  ≤-refl (suc m) = s≤s (≤-refl m)

  ≤-trans : ∀ {a b c} → a ≤ b → b ≤ c → a ≤ c
  ≤-trans z≤n       _         = z≤n
  ≤-trans (s≤s a≤b) (s≤s b≤c) = s≤s (≤-trans a≤b b≤c)

  n≤1+n : ∀ n → n ≤ suc n
  n≤1+n zero    = z≤n
  n≤1+n (suc n) = s≤s (n≤1+n n)

  m≤m+n : ∀ m n → m ≤ m + n
  m≤m+n zero    _ = z≤n
  m≤m+n (suc m) n = s≤s (m≤m+n m n)

  m≤n+m : ∀ n m → m ≤ n + m
  m≤n+m zero    m = ≤-refl m
  m≤n+m (suc n) m = ≤-trans (m≤n+m n m) (n≤1+n (n + m))

  +-mono-≤ : ∀ {a b c d} → a ≤ b → c ≤ d → a + c ≤ b + d
  +-mono-≤ {_} {b} {_} {d} z≤n       c≤d = ≤-trans c≤d (m≤n+m b d)
  +-mono-≤                 (s≤s a≤b) c≤d = s≤s (+-mono-≤ a≤b c≤d)

  m∸n≤m : ∀ m n → (m ∸ n) ≤ m
  m∸n≤m zero    zero    = z≤n
  m∸n≤m zero    (suc _) = z≤n
  m∸n≤m (suc m) zero    = ≤-refl (suc m)
  m∸n≤m (suc m) (suc n) = ≤-trans (m∸n≤m m n) (n≤1+n m)

  ∨-left : ∀ {b : Bool} c → b ≡ true → (b ∨ c) ≡ true
  ∨-left {true}  _ _ = refl
  ∨-left {false} _ ()

  ∨-right : ∀ b {c : Bool} → c ≡ true → (b ∨ c) ≡ true
  ∨-right true  _  = refl
  ∨-right false eq = eq

  ∨-mono : ∀ {a₁ a₂ b₁ b₂ : Bool} →
    (a₁ ≡ true → a₂ ≡ true) →
    (b₁ ≡ true → b₂ ≡ true) →
    (a₁ ∨ b₁) ≡ true →
    (a₂ ∨ b₂) ≡ true
  ∨-mono {false} {a₂}    {_} {_} _  gb eq = ∨-right a₂ (gb eq)
  ∨-mono {true}  {true}  {_} {_} _  _  _  = refl
  ∨-mono {true}  {false} {_} {_} ga _  _  = false≢true (ga refl)

  ∧-proj₁ : ∀ {a b : Bool} → (a ∧ b) ≡ true → a ≡ true
  ∧-proj₁ {true}  {_} _  = refl
  ∧-proj₁ {false} {_} ()

  not-∧-false : ∀ {b : Bool} c → b ≡ true → (not b ∧ c) ≡ false
  not-∧-false {true}  _ _ = refl
  not-∧-false {false} _ ()

  if-mono : ∀ len {b₁ b₂ : Bool} →
    (b₁ ≡ true → b₂ ≡ true) →
    (if b₁ then len else zero) ≤ (if b₂ then len else zero)
  if-mono _   {false} {_}     _   = z≤n
  if-mono len {true}  {true}  _   = ≤-refl len
  if-mono _   {true}  {false} imp = false≢true (imp refl)

------------------------------------------------------------------------
-- Epistemic world admissibility (`present_in_every_admissible_world`)

World : Set
World = ℕ → Bool

allWorlds : (World → Bool) → List World → Bool
allWorlds _ []       = true
allWorlds p (w ∷ ws) = p w ∧ allWorlds p ws

anyWorld : (World → Bool) → List World → Bool
anyWorld _ []       = false
anyWorld p (w ∷ ws) = p w ∨ anyWorld p ws

-- An empty world fibre has no warrant and is never vacuously universal.
presentInEvery : List World → ℕ → Bool
presentInEvery []       _ = false
presentInEvery (w ∷ ws) k = w k ∧ allWorlds (λ v → v k) ws

presentInSome : List World → ℕ → Bool
presentInSome ws k = anyWorld (λ v → v k) ws

absentInEvery : List World → ℕ → Bool
absentInEvery []       _ = false
absentInEvery (w ∷ ws) k = not (w k) ∧ allWorlds (λ v → not (v k)) ws

every⇒some : ∀ ws k → presentInEvery ws k ≡ true → presentInSome ws k ≡ true
every⇒some []       _ ()
every⇒some (_ ∷ ws) k eq = ∨-left (anyWorld (λ v → v k) ws) (∧-proj₁ eq)

every⇒not-absent : ∀ ws k → presentInEvery ws k ≡ true → absentInEvery ws k ≡ false
every⇒not-absent []       _ ()
every⇒not-absent (w ∷ ws) k eq = not-∧-false (allWorlds (λ v → not (v k)) ws) (∧-proj₁ eq)

------------------------------------------------------------------------
-- Drag-and-drop clade reassignment gate

data MoveVerdict : Set where
  accepted : MoveVerdict
  rejected : MoveVerdict

validateMove : (ws : List World) → (target : ℕ) → (notSelf acyclic : Bool) → MoveVerdict
validateMove ws target notSelf acyclic =
  if notSelf ∧ (acyclic ∧ presentInEvery ws target)
  then accepted
  else rejected

private
  move-helper : ∀ (b : Bool) →
    (if b then accepted else rejected) ≡ accepted → b ≡ true
  move-helper true  _  = refl
  move-helper false ()

validateMove-sound :
  ∀ ws target notSelf acyclic →
  validateMove ws target notSelf acyclic ≡ accepted →
  (notSelf ≡ true) × ((acyclic ≡ true) × (presentInEvery ws target ≡ true))
validateMove-sound _  _      false _     ()
validateMove-sound _  _      true  false ()
validateMove-sound ws target true  true  eq =
  refl , (refl , move-helper (presentInEvery ws target) eq)

------------------------------------------------------------------------
-- CladeTree topology and bottom-up read aggregation

mutual
  data CladeTree : Set where
    tip   : (id : ℕ) → (reads : ℕ) → (branchLen : ℕ) → CladeTree
    clade : (id : ℕ) → (branchLen : ℕ) → (children : CladeForest) → CladeTree

  data CladeForest : Set where
    empty : CladeForest
    _∷ᶠ_  : CladeTree → CladeForest → CladeForest

data _∈ᶠ_ : CladeTree → CladeForest → Set where
  hereᶠ  : ∀ {t ts} → t ∈ᶠ (t ∷ᶠ ts)
  thereᶠ : ∀ {t u ts} → t ∈ᶠ ts → t ∈ᶠ (u ∷ᶠ ts)

sumReads : List ℕ → ℕ
sumReads []       = zero
sumReads (r ∷ rs) = r + sumReads rs

private
  sumReads-++ : ∀ xs ys → sumReads (xs ++ ys) ≡ sumReads xs + sumReads ys
  sumReads-++ []       _  = refl
  sumReads-++ (x ∷ xs) ys =
    trans (cong (x +_) (sumReads-++ xs ys))
          (sym (+-assoc x (sumReads xs) (sumReads ys)))

mutual
  cumulativeCount : CladeTree → ℕ
  cumulativeCount (tip _ r _)    = r
  cumulativeCount (clade _ _ cs) = forestCount cs

  forestCount : CladeForest → ℕ
  forestCount empty     = zero
  forestCount (t ∷ᶠ ts) = cumulativeCount t + forestCount ts

mutual
  tipsReads : CladeTree → List ℕ
  tipsReads (tip _ r _)    = r ∷ []
  tipsReads (clade _ _ cs) = forestTipsReads cs

  forestTipsReads : CladeForest → List ℕ
  forestTipsReads empty     = []
  forestTipsReads (t ∷ᶠ ts) = tipsReads t ++ forestTipsReads ts

mutual
  cumulative-conserves-tips : ∀ t → cumulativeCount t ≡ sumReads (tipsReads t)
  cumulative-conserves-tips (tip _ r _)    = sym (+-idʳ r)
  cumulative-conserves-tips (clade _ _ cs) = forest-conserves-tips cs

  forest-conserves-tips : ∀ cs → forestCount cs ≡ sumReads (forestTipsReads cs)
  forest-conserves-tips empty     = refl
  forest-conserves-tips (t ∷ᶠ ts) =
    trans (cong₂ _+_ (cumulative-conserves-tips t) (forest-conserves-tips ts))
          (sym (sumReads-++ (tipsReads t) (forestTipsReads ts)))

child≤forest : ∀ {t cs} → t ∈ᶠ cs → cumulativeCount t ≤ forestCount cs
child≤forest (hereᶠ {t} {ts})               = m≤m+n (cumulativeCount t) (forestCount ts)
child≤forest (thereᶠ {u = u} {ts = ts} mem) =
  ≤-trans (child≤forest mem) (m≤n+m (cumulativeCount u) (forestCount ts))

child≤parent : ∀ {child id len cs} → child ∈ᶠ cs →
  cumulativeCount child ≤ cumulativeCount (clade id len cs)
child≤parent = child≤forest

------------------------------------------------------------------------
-- Phylogenetic Diversity: Faith's PD and Unweighted UniFrac bounds

_⊆_ : (ℕ → Bool) → (ℕ → Bool) → Set
S₁ ⊆ S₂ = ∀ k → S₁ k ≡ true → S₂ k ≡ true

unionSet : (ℕ → Bool) → (ℕ → Bool) → (ℕ → Bool)
unionSet S₁ S₂ k = S₁ k ∨ S₂ k

allTips : ℕ → Bool
allTips _ = true

mutual
  active : (ℕ → Bool) → CladeTree → Bool
  active S (tip id _ _)   = S id
  active S (clade _ _ cs) = anyActive S cs

  anyActive : (ℕ → Bool) → CladeForest → Bool
  anyActive _ empty     = false
  anyActive S (t ∷ᶠ ts) = active S t ∨ anyActive S ts

mutual
  active-mono : ∀ {S₁ S₂} → S₁ ⊆ S₂ → ∀ t → active S₁ t ≡ true → active S₂ t ≡ true
  active-mono inc (tip id _ _)   eq = inc id eq
  active-mono inc (clade _ _ cs) eq = anyActive-mono inc cs eq

  anyActive-mono : ∀ {S₁ S₂} → S₁ ⊆ S₂ → ∀ cs → anyActive S₁ cs ≡ true → anyActive S₂ cs ≡ true
  anyActive-mono _   empty     ()
  anyActive-mono inc (t ∷ᶠ ts) eq =
    ∨-mono (λ h → active-mono inc t h) (λ h → anyActive-mono inc ts h) eq

mutual
  faithPD : (ℕ → Bool) → CladeTree → ℕ
  faithPD S t@(tip _ _ len)    = if active S t then len else zero
  faithPD S t@(clade _ len cs) = (if active S t then len else zero) + forestPD S cs

  forestPD : (ℕ → Bool) → CladeForest → ℕ
  forestPD _ empty     = zero
  forestPD S (t ∷ᶠ ts) = faithPD S t + forestPD S ts

totalTreePD : CladeTree → ℕ
totalTreePD = faithPD allTips

mutual
  faithPD-mono : ∀ {S₁ S₂} → S₁ ⊆ S₂ → ∀ t → faithPD S₁ t ≤ faithPD S₂ t
  faithPD-mono inc t@(tip _ _ len)    = if-mono len (λ h → active-mono inc t h)
  faithPD-mono inc t@(clade _ len cs) =
    +-mono-≤ (if-mono len (λ h → active-mono inc t h)) (forestPD-mono inc cs)

  forestPD-mono : ∀ {S₁ S₂} → S₁ ⊆ S₂ → ∀ cs → forestPD S₁ cs ≤ forestPD S₂ cs
  forestPD-mono _   empty     = z≤n
  forestPD-mono inc (t ∷ᶠ ts) = +-mono-≤ (faithPD-mono inc t) (forestPD-mono inc ts)

faithPD-bounded : ∀ S t → faithPD S t ≤ totalTreePD t
faithPD-bounded _ = faithPD-mono (λ _ _ → refl)

private
  ⊆-unionˡ : ∀ S₁ S₂ → S₁ ⊆ unionSet S₁ S₂
  ⊆-unionˡ _ S₂ k eq = ∨-left (S₂ k) eq

  both⇒union : ∀ S₁ S₂ t →
    (active S₁ t ∧ active S₂ t) ≡ true →
    active (unionSet S₁ S₂) t ≡ true
  both⇒union S₁ S₂ t eq =
    active-mono (⊆-unionˡ S₁ S₂) t (∧-proj₁ eq)

mutual
  sharedPD : (ℕ → Bool) → (ℕ → Bool) → CladeTree → ℕ
  sharedPD S₁ S₂ t@(tip _ _ len) =
    if active S₁ t ∧ active S₂ t then len else zero
  sharedPD S₁ S₂ t@(clade _ len cs) =
    (if active S₁ t ∧ active S₂ t then len else zero) + forestSharedPD S₁ S₂ cs

  forestSharedPD : (ℕ → Bool) → (ℕ → Bool) → CladeForest → ℕ
  forestSharedPD _  _  empty     = zero
  forestSharedPD S₁ S₂ (t ∷ᶠ ts) = sharedPD S₁ S₂ t + forestSharedPD S₁ S₂ ts

mutual
  sharedPD≤unionPD : ∀ S₁ S₂ t → sharedPD S₁ S₂ t ≤ faithPD (unionSet S₁ S₂) t
  sharedPD≤unionPD S₁ S₂ t@(tip _ _ len) =
    if-mono len (both⇒union S₁ S₂ t)
  sharedPD≤unionPD S₁ S₂ t@(clade _ len cs) =
    +-mono-≤ (if-mono len (both⇒union S₁ S₂ t)) (forestShared≤Union S₁ S₂ cs)

  forestShared≤Union : ∀ S₁ S₂ cs →
    forestSharedPD S₁ S₂ cs ≤ forestPD (unionSet S₁ S₂) cs
  forestShared≤Union _  _  empty     = z≤n
  forestShared≤Union S₁ S₂ (t ∷ᶠ ts) =
    +-mono-≤ (sharedPD≤unionPD S₁ S₂ t) (forestShared≤Union S₁ S₂ ts)

unifracNumerator≤Denominator : ∀ S₁ S₂ t →
  (faithPD (unionSet S₁ S₂) t ∸ sharedPD S₁ S₂ t) ≤ faithPD (unionSet S₁ S₂) t
unifracNumerator≤Denominator S₁ S₂ t =
  m∸n≤m (faithPD (unionSet S₁ S₂) t) (sharedPD S₁ S₂ t)
