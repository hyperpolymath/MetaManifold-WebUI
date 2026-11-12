# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Independent awk reference oracle for Issue #19 constrained ordinations
# (RDA, partial RDA with Condition(...), CLR/Aitchison and Hellinger geometries,
# Ezekiel adjusted-R2, Jacobi eigenvalues, and Peres-Neto two-way variance
# partitioning), plus RFC 7493 I-JSON / RFC 8785 JCS canonical verification for
# the constrained-ordination schema and reference fixture.
#
# This is a port of check_ordination_references.py. All the linear algebra is
# hand-written here in plain double precision awk and shares no maths code with
# Julia (no LAPACK, no MPFR). It runs under POSIX awk and under mawk 1.3.4.
# It is driven by check_ordination_references.sh, which passes settings in the
# environment (ORD_*). Messages go to stderr; success prints one line.
#
# Floating point order of operations is kept the same as the Python, including
# the compensated sum() of CPython 3.12 and later (see padd below).

# ---------------------------------------------------------------- utilities

function die(msg) {
  print "error: " msg > "/dev/stderr"
  exit 1
}

function abs(x) { return x < 0 ? -x : x }

# Python float division raises on a zero divisor, so do the same here.
function fdiv(a, b) {
  if (b == 0) die("float division by zero")
  return a / b
}

function mlog(x) {
  if (x <= 0) die("math domain error: log of non-positive value")
  return log(x)
}

function msqrt(x) {
  if (x < 0) die("math domain error: sqrt of negative value")
  return sqrt(x)
}

# Python round(x, d) for finite x: correctly rounded decimal text, read back.
function rnd(x, d) { return sprintf("%." d "f", x) + 0 }

function zeros(c,   z) {
  if (c <= 0) return ""
  z = sprintf("%" c "s", "")
  gsub(/ /, "0", z)
  return z
}

function init_tables(   i) {
  for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
  NULCH = sprintf("%c", 0)
  MAXF = 1.7976931348623157e308
}

# ------------------------------------------------- compensated sum (CPython)
# CPython 3.12+ sum(): ints are added exactly while no float has been seen.
# The first float switches to float mode (plain add). From then on floats use
# Neumaier compensation and ints are added plainly. The caller says whether
# each item is an int (isint) so mixed int and float lists match CPython.

function pinit() { PS_M = 0; PS_F = 0; PS_C = 0 }

function padd(x, isint,   t) {
  if (PS_M == 0) {
    if (isint) { PS_F += x; return }
    PS_M = 1
    PS_F = PS_F + x
    return
  }
  if (isint) { PS_F += x; return }
  t = PS_F + x
  if (abs(PS_F) >= abs(x)) PS_C += (PS_F - t) + x
  else PS_C += (x - t) + PS_F
  PS_F = t
}

function pres() {
  if (PS_M == 1 && PS_C != 0) return PS_F + PS_C
  return PS_F
}

# ------------------------------------------------------------ JSON parsing
# Tree storage. Node types: o a s i f T F N (object, array, string, int,
# float, true, false, null). Kids of o and a are KID[id,k], k = 1..NK[id].
# Object keys: KEY (JCS escaped form), SK (UTF-16 code unit hex, for sorting
# and lookup), KBAD (I-JSON problem). Strings: V escaped form, D decoded bytes,
# BAD problem text. Numbers: V value, BAD problem text.

function newnode(t) {
  NID++
  T[NID] = t
  NK[NID] = 0
  return NID
}

function jerr(msg) { die("JSON parse error: " msg " (char " POS ")") }

function skipws(   c) {
  while (POS <= TL) {
    c = substr(TXT, POS, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") POS++
    else break
  }
}

function hex2num(h,   i, n, d) {
  n = 0
  for (i = 1; i <= length(h); i++) {
    d = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (d == 0) return -1
    n = n * 16 + d - 1
  }
  return n
}

function askhex(s,   i, r) {
  r = ""
  for (i = 1; i <= length(s); i++) r = r sprintf("%04x", ORD[substr(s, i, 1)])
  return r
}

function u16hex(cp) {
  if (cp < 65536) return sprintf("%04x", cp)
  cp -= 65536
  return sprintf("%04x%04x", 55296 + int(cp / 1024), 56320 + cp % 1024)
}

function utf8enc(cp) {
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}

# Append one code point to the string being built in S_ESC, S_DEC, S_SK.
function emitcp(cp, wantsk,   ch) {
  if ((cp >= 64976 && cp <= 65007) || (cp % 65536) >= 65534) {
    if (S_BAD == "") S_BAD = sprintf("Unicode noncharacter U+%04X forbidden in I-JSON", cp)
  }
  if (wantsk) S_SK = S_SK u16hex(cp)
  if (cp == 34) { S_ESC = S_ESC "\\\""; S_DEC = S_DEC "\""; return }
  if (cp == 92) { S_ESC = S_ESC "\\\\"; S_DEC = S_DEC "\\"; return }
  if (cp < 32) {
    if (cp == 8) S_ESC = S_ESC "\\b"
    else if (cp == 9) S_ESC = S_ESC "\\t"
    else if (cp == 10) S_ESC = S_ESC "\\n"
    else if (cp == 12) S_ESC = S_ESC "\\f"
    else if (cp == 13) S_ESC = S_ESC "\\r"
    else S_ESC = S_ESC sprintf("\\u%04x", cp)
    S_DEC = S_DEC sprintf("%c", cp)
    return
  }
  ch = utf8enc(cp)
  S_ESC = S_ESC ch
  S_DEC = S_DEC ch
}

function u4(p,   h) {
  h = substr(TXT, p, 4)
  if (length(h) < 4) return -1
  return hex2num(h)
}

# Parse a JSON string at POS (on the opening quote). Strict UTF-8 decoding.
function pstr(wantsk,   w, n, run, c, e, cp, lo, b1, need, k, b, loB, hiB) {
  S_ESC = "\""; S_DEC = ""; S_SK = ""; S_BAD = ""
  POS++
  while (1) {
    if (POS > TL) jerr("Unterminated string")
    w = substr(TXT, POS, 96)
    if (match(w, /^[^"\\\001-\037\200-\377]+/)) {
      n = RLENGTH
      run = substr(w, 1, n)
      S_ESC = S_ESC run
      S_DEC = S_DEC run
      if (wantsk) S_SK = S_SK askhex(run)
      POS += n
      continue
    }
    c = substr(w, 1, 1)
    if (c == "\"") { POS++; S_ESC = S_ESC "\""; return }
    if (c == "\\") {
      e = substr(TXT, POS + 1, 1)
      if (e == "u") {
        cp = u4(POS + 2)
        if (cp < 0) jerr("Invalid \\uXXXX escape")
        POS += 6
        if (cp >= 55296 && cp <= 56319 && substr(TXT, POS, 2) == "\\u") {
          lo = u4(POS + 2)
          if (lo < 0) jerr("Invalid \\uXXXX escape")
          if (lo >= 56320 && lo <= 57343) {
            cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
            POS += 6
          }
        }
        if (cp >= 55296 && cp <= 57343) {
          if (S_BAD == "") S_BAD = sprintf("Lone surrogate U+%04X forbidden in I-JSON", cp)
          if (wantsk) S_SK = S_SK sprintf("%04x", cp)
          S_DEC = S_DEC "?"
        } else emitcp(cp, wantsk)
        continue
      }
      if (e == "\"") emitcp(34, wantsk)
      else if (e == "\\") emitcp(92, wantsk)
      else if (e == "/") emitcp(47, wantsk)
      else if (e == "b") emitcp(8, wantsk)
      else if (e == "f") emitcp(12, wantsk)
      else if (e == "n") emitcp(10, wantsk)
      else if (e == "r") emitcp(13, wantsk)
      else if (e == "t") emitcp(9, wantsk)
      else jerr("Invalid \\escape")
      POS += 2
      continue
    }
    b1 = ORD[c]
    if (b1 < 32) jerr("Invalid control character in string")
    if (b1 >= 194 && b1 <= 223) { need = 1; cp = b1 - 192; loB = 128; hiB = 191 }
    else if (b1 >= 224 && b1 <= 239) { need = 2; cp = b1 - 224; loB = (b1 == 224) ? 160 : 128; hiB = (b1 == 237) ? 159 : 191 }
    else if (b1 >= 240 && b1 <= 244) { need = 3; cp = b1 - 240; loB = (b1 == 240) ? 144 : 128; hiB = (b1 == 244) ? 143 : 191 }
    else jerr("invalid UTF-8 byte")
    for (k = 1; k <= need; k++) {
      if (POS + k > TL) jerr("truncated UTF-8 sequence")
      b = ORD[substr(TXT, POS + k, 1)]
      if (k > 1) { loB = 128; hiB = 191 }
      if (b < loB || b > hiB) jerr("invalid UTF-8 sequence")
      cp = cp * 64 + (b - 128)
    }
    POS += need + 1
    emitcp(cp, wantsk)
  }
}

function addmember(o, key, sk, kbad, v,   i) {
  if ((o, sk) in KIDX) {
    i = KIDX[o, sk]
    KID[o, i] = v
    return
  }
  i = ++NK[o]
  KIDX[o, sk] = i
  KID[o, i] = v
  KEY[o, i] = key
  SK[o, i] = sk
  KBAD[o, i] = kbad
}

function pobj(   id, k, sk, kb, v, c) {
  id = newnode("o")
  POS++
  skipws()
  if (substr(TXT, POS, 1) == "}") { POS++; return id }
  while (1) {
    skipws()
    if (substr(TXT, POS, 1) != "\"") jerr("Expecting property name enclosed in double quotes")
    pstr(1)
    k = S_ESC; sk = S_SK; kb = S_BAD
    skipws()
    if (substr(TXT, POS, 1) != ":") jerr("Expecting ':' delimiter")
    POS++
    v = pval()
    addmember(id, k, sk, kb, v)
    skipws()
    c = substr(TXT, POS, 1)
    if (c == "}") { POS++; return id }
    if (c != ",") jerr("Expecting ',' delimiter")
    POS++
  }
}

function parr(   id, v, c) {
  id = newnode("a")
  POS++
  skipws()
  if (substr(TXT, POS, 1) == "]") { POS++; return id }
  while (1) {
    v = pval()
    NK[id]++
    KID[id, NK[id]] = v
    skipws()
    c = substr(TXT, POS, 1)
    if (c == "]") { POS++; return id }
    if (c != ",") jerr("Expecting ',' delimiter")
    POS++
  }
}

function pval(   c, id, w, win, txt, ds) {
  skipws()
  if (POS > TL) jerr("Expecting value")
  c = substr(TXT, POS, 1)
  if (c == "{") return pobj()
  if (c == "[") return parr()
  if (c == "\"") {
    pstr(0)
    id = newnode("s")
    V[id] = S_ESC; D[id] = S_DEC; BAD[id] = S_BAD
    return id
  }
  if (substr(TXT, POS, 4) == "true") { POS += 4; return newnode("T") }
  if (substr(TXT, POS, 5) == "false") { POS += 5; return newnode("F") }
  if (substr(TXT, POS, 4) == "null") { POS += 4; return newnode("N") }
  win = 64
  while (1) {
    w = substr(TXT, POS, win)
    match(w, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/)
    if (RLENGTH < length(w) || length(w) < win) break
    win *= 4
  }
  if (RSTART == 0 || RLENGTH <= 0) jerr("Expecting value")
  txt = substr(w, 1, RLENGTH)
  POS += RLENGTH
  if (txt ~ /[.eE]/) {
    id = newnode("f")
    V[id] = txt + 0
    BAD[id] = ""
    if (V[id] > MAXF || V[id] < -MAXF) BAD[id] = "Non-finite float forbidden in I-JSON/JCS"
  } else {
    id = newnode("i")
    V[id] = txt + 0
    BAD[id] = ""
    ds = txt
    sub(/^-/, "", ds)
    if (length(ds) > 16 || (length(ds) == 16 && (ds "") > "9007199254740991"))
      BAD[id] = "Integer " txt " outside I-JSON safe range"
  }
  return id
}

function parse_json(text) {
  TXT = text
  TL = length(text)
  POS = 1
  ROOT = pval()
  skipws()
  if (POS <= TL) jerr("Extra data")
  return ROOT
}

# Object lookup by ASCII key name. Returns the kid id or 0.
function getk(o, name,   sk) {
  sk = askhex(name)
  if ((o, sk) in KIDX) return KID[o, KIDX[o, sk]]
  return 0
}

# ------------------------------------------------------------ JCS (RFC 8785)

function fmtfloat(x,   neg, ax, nd, s, ep, dg, ex, k, n, body, mant, sg) {
  if (x == 0) return "0"
  neg = (x < 0)
  ax = neg ? -x : x
  # shortest digit count that reads back to the same double
  for (nd = 1; nd <= 17; nd++) {
    s = sprintf("%." (nd - 1) "e", ax)
    if ((s + 0) == ax) break
  }
  ep = index(s, "e")
  dg = substr(s, 1, ep - 1)
  ex = substr(s, ep + 1) + 0
  gsub(/\./, "", dg)
  sub(/0+$/, "", dg)
  k = length(dg)
  n = ex + 1
  if (k <= n && n <= 21) body = dg zeros(n - k)
  else if (0 < n && n <= 21) body = substr(dg, 1, n) "." substr(dg, n + 1)
  else if (-5 <= n && n <= 0) body = "0." zeros(-n) dg
  else {
    sg = (n - 1 >= 0) ? "+" : "-"
    mant = (k == 1) ? dg : (substr(dg, 1, 1) "." substr(dg, 2))
    body = mant "e" sg abs(n - 1)
  }
  return neg ? ("-" body) : body
}

function jcs(id,   t, i, n, s, ix, j, tmp) {
  t = T[id]
  if (t == "N") return "null"
  if (t == "T") return "true"
  if (t == "F") return "false"
  if (t == "i") {
    if (BAD[id] != "") die(BAD[id])
    return sprintf("%.0f", V[id])
  }
  if (t == "f") {
    if (BAD[id] != "") die(BAD[id])
    return fmtfloat(V[id])
  }
  if (t == "s") {
    if (BAD[id] != "") die(BAD[id])
    return V[id]
  }
  if (t == "a") {
    s = "["
    for (i = 1; i <= NK[id]; i++) s = s (i > 1 ? "," : "") jcs(KID[id, i])
    return s "]"
  }
  n = NK[id]
  for (i = 1; i <= n; i++) ix[i] = i
  for (i = 2; i <= n; i++) {
    tmp = ix[i]
    j = i - 1
    while (j >= 1 && ((SK[id, ix[j]] "") > (SK[id, tmp] ""))) { ix[j + 1] = ix[j]; j-- }
    ix[j + 1] = tmp
  }
  s = "{"
  for (i = 1; i <= n; i++) {
    if (KBAD[id, ix[i]] != "") die(KBAD[id, ix[i]])
    s = s (i > 1 ? "," : "") KEY[id, ix[i]] ":" jcs(KID[id, ix[i]])
  }
  return s "}"
}

# ----------------------------------------------------------------- file I/O

# Python-style whitespace for str.strip().
function lstrip(s) {
  sub(/^([ \t\r\013\014\034-\037]|\302[\205\240]|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200)+/, "", s)
  return s
}
function rstrip(s) {
  sub(/([ \t\r\013\014\034-\037]|\302[\205\240]|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200)+$/, "", s)
  return s
}
function pystrip(s) { return rstrip(lstrip(s)) }

function utf8valid(s) {
  return s ~ /^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|[\356\357][\200-\277][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/
}

# Whole file as text, lines joined by LF (no final LF). Dies if unreadable.
function slurp(path,   line, r, text, first) {
  text = ""; first = 1
  while ((r = (getline line < path)) > 0) {
    if (index(line, NULCH)) die(path ": NUL byte in file")
    text = first ? line : (text "\n" line)
    first = 0
  }
  close(path)
  if (r < 0) die("cannot read " path)
  return text
}

# Lines as str.splitlines() would give them. Sets RL_TEXT to the whole text.
function readlines(path, L,   line, r, n, parts, np, i, tmp, c) {
  n = 0; c = 0; RL_TEXT = ""
  delete L
  while ((r = (getline line < path)) > 0) {
    if (index(line, NULCH)) die(path ": NUL byte in file")
    if (!utf8valid(line)) die(path ": invalid UTF-8")
    RL_TEXT = c ? (RL_TEXT "\n" line) : line
    c = 1
    sub(/\r$/, "", line)
    tmp = line
    gsub(/[\013\014\015\034-\036]|\302\205|\342\200[\250\251]/, "\n", tmp)
    np = split(tmp, parts, "\n")
    for (i = 1; i <= np; i++) L[++n] = parts[i]
  }
  close(path)
  if (r < 0) die("cannot read " path)
  return n
}

# verify_jcs_file: LF check done by the driver (lfok), then parse and compare.
function verify_jcs_file(path, lfok,   text, root, canon) {
  if (!lfok) die(path ": must end with exactly one trailing LF")
  text = slurp(path)
  if (!utf8valid(text)) die(path ": invalid UTF-8")
  root = parse_json(text)
  canon = jcs(root)
  if ((text "") != (canon "")) die(path ": content is not byte-for-byte RFC 8785 JCS")
  return root
}

function check_oracle(path,   probe, L, n, i, root, inp, ex_, out) {
  if ((getline probe < path) < 0) return
  close(path)
  n = readlines(path, L)
  for (i = 1; i <= n; i++) {
    if (pystrip(L[i]) == "") continue
    root = parse_json(L[i])
    if (T[root] != "o") die("jcs_oracle.jsonl line " i ": not an object")
    inp = getk(root, "input"); ex_ = getk(root, "expected")
    if (!inp || !ex_) die("jcs_oracle.jsonl line " i ": missing input or expected")
    out = jcs(inp)
    if (T[ex_] != "s" || BAD[ex_] != "" || (out "") != (D[ex_] ""))
      die("jcs_oracle.jsonl line " i " mismatch")
  }
}

# ------------------------------------------------------------ KYAML contract

function verify_kyaml(path,   L, n, i, s, B, nb, toks, nt, text, t, g, val, m) {
  n = readlines(path, L)
  text = RL_TEXT
  nb = 0
  for (i = 1; i <= n; i++) {
    s = pystrip(L[i])
    if (s != "" && substr(s, 1, 1) != "#") B[++nb] = s
  }
  if (nb == 0 || B[1] != "---") die(path ": KYAML must open with explicit '---' after SPDX comments")
  if (nb < 2 || B[2] != "{") die(path ": KYAML top-level mapping must use explicit '{' flow syntax")
  if (B[nb] != "}") die(path ": KYAML top-level mapping must close with '}'")
  nt = split("rda: cca: cap: dbrda: \"capscale\" \"aitchison\" \"chisq\" 99 9999", toks, " ")
  for (i = 1; i <= nt; i++)
    if (index(text, toks[i]) == 0) die(path ": missing expected contract token " toks[i])
  for (i = 1; i <= n; i++) {
    s = pystrip(L[i])
    if (s == "" || substr(s, 1, 1) == "#") continue
    if (s == "---" || s == "{" || s == "}" || s == "}," || s == "],") continue
    if (match(s, /^[A-Za-z0-9_"']+:/)) {
      t = lstrip(substr(s, RLENGTH + 1))
      if (t == "") continue
      g = t
      if (substr(t, length(t), 1) == ",") {
        g = rstrip(substr(t, 1, length(t) - 1))
        if (g == "") g = t
      }
      val = g
      sub(/,+$/, "", val)
      val = pystrip(val)
      if (val == "{" || val == "[" || substr(val, 1, 1) == "\"" || val == "true" || val == "false" || val == "null") continue
      if (val ~ /^-?[0-9]+(\.[0-9]+)?$/) continue
      die(path ":" i ": unquoted scalar value '" val "' violates KYAML")
    }
  }
}

# --------------------------------------------------- numeric reference engine
# Matrices are arrays M[i,j] (0-based), with int flags MI[i,j] (1 when the
# value came from a JSON integer) and dimensions passed in n and p.

function centre(M, MI, n, p, OUT,   i, j, mean) {
  for (j = 0; j < p; j++) {
    pinit()
    for (i = 0; i < n; i++) padd(M[i, j], MI[i, j])
    mean = fdiv(pres(), n)
    for (i = 0; i < n; i++) OUT[i, j] = M[i, j] - mean
  }
}

# Modified Gram-Schmidt with one re-orthogonalisation. Basis vectors go to
# Q[b,i]. Returns the number of vectors kept.
# MI flags JSON ints: while no basis vector exists the column is still int
# typed, so its squared norm is summed as exact ints (as CPython does).
function mgs(M, MI, n, m, Q,   j, i, b, nb, rep, proj, norm) {
  nb = 0
  for (j = 0; j < m; j++) {
    for (i = 0; i < n; i++) VV[i] = M[i, j]
    for (rep = 0; rep < 2; rep++) {
      for (b = 0; b < nb; b++) {
        pinit()
        for (i = 0; i < n; i++) padd(Q[b, i] * VV[i], 0)
        proj = pres()
        for (i = 0; i < n; i++) VV[i] -= proj * Q[b, i]
      }
    }
    pinit()
    for (i = 0; i < n; i++) padd(VV[i] * VV[i], nb == 0 ? MI[i, j] : 0)
    norm = msqrt(pres())
    if (norm > 1e-11) {
      for (i = 0; i < n; i++) Q[nb, i] = VV[i] / norm
      nb++
    }
  }
  return nb
}

function project(Q, nb, M, n, p, OUT,   b, i, j, dot) {
  for (i = 0; i < n; i++) for (j = 0; j < p; j++) OUT[i, j] = 0
  for (b = 0; b < nb; b++) {
    for (j = 0; j < p; j++) {
      pinit()
      for (i = 0; i < n; i++) padd(Q[b, i] * M[i, j], 0)
      dot = pres()
      for (i = 0; i < n; i++) OUT[i, j] += Q[b, i] * dot
    }
  }
}

function sub_mat(A, B, n, p, OUT,   i, j) {
  for (i = 0; i < n; i++) for (j = 0; j < p; j++) OUT[i, j] = A[i, j] - B[i, j]
}

function frob_sq(M, n, p,   i, j) {
  pinit()
  for (i = 0; i < n; i++) for (j = 0; j < p; j++) padd(M[i, j] * M[i, j], 0)
  return pres()
}

# Eigenvalues of a symmetric m x m matrix by cyclic Jacobi rotations, sorted
# descending, tiny ones dropped. Result in E[0..count-1]; returns count.
function jacobi(S, m, E,   tol, i, j, p, q, r, sweep, maxoff, apq, tau, t, c, s, app, aqq, arp, arq, cnt, v, cutoff, h, tmp, vals) {
  tol = 1e-13
  if (m == 0) return 0
  if (m == 1) {
    if (S[0, 0] > tol) { E[0] = S[0, 0]; return 1 }
    return 0
  }
  for (i = 0; i < m; i++) for (j = 0; j < m; j++) JA[i, j] = 0.5 * (S[i, j] + S[j, i])
  for (sweep = 0; sweep < 90; sweep++) {
    maxoff = 0
    for (p = 0; p < m - 1; p++)
      for (q = p + 1; q < m; q++)
        if (abs(JA[p, q]) > maxoff) maxoff = abs(JA[p, q])
    if (maxoff <= tol) break
    for (p = 0; p < m - 1; p++) {
      for (q = p + 1; q < m; q++) {
        apq = JA[p, q]
        if (abs(apq) <= tol) continue
        tau = (JA[q, q] - JA[p, p]) / (2.0 * apq)
        if (tau >= 0) t = 1.0 / (tau + sqrt(1.0 + tau * tau))
        else t = -1.0 / (-tau + sqrt(1.0 + tau * tau))
        c = 1.0 / sqrt(1.0 + t * t)
        s = t * c
        app = JA[p, p]
        aqq = JA[q, q]
        JA[p, p] = app - t * apq
        JA[q, q] = aqq + t * apq
        JA[p, q] = 0
        JA[q, p] = 0
        for (r = 0; r < m; r++) {
          if (r == p || r == q) continue
          arp = JA[r, p]
          arq = JA[r, q]
          JA[r, p] = c * arp - s * arq
          JA[p, r] = JA[r, p]
          JA[r, q] = s * arp + c * arq
          JA[q, r] = JA[r, q]
        }
      }
    }
  }
  for (i = 0; i < m; i++) vals[i] = JA[i, i]
  for (i = 1; i < m; i++) {
    tmp = vals[i]
    j = i - 1
    while (j >= 0 && vals[j] < tmp) { vals[j + 1] = vals[j]; j-- }
    vals[j + 1] = tmp
  }
  cutoff = 1e-12 * (vals[0] > 1.0 ? vals[0] : 1.0)
  if (!(cutoff > tol)) cutoff = tol
  cnt = 0
  for (i = 0; i < m; i++) if (vals[i] > cutoff) E[cnt++] = vals[i]
  return cnt
}

function gram_eigs(M, n, p, dof, E,   i, j, k, m) {
  if (n <= p) {
    m = n
    for (i = 0; i < n; i++) for (j = 0; j < n; j++) {
      pinit()
      for (k = 0; k < p; k++) padd(M[i, k] * M[j, k], 0)
      GG[i, j] = fdiv(pres(), dof)
    }
  } else {
    m = p
    for (i = 0; i < p; i++) for (j = 0; j < p; j++) {
      pinit()
      for (k = 0; k < n; k++) padd(M[k, i] * M[k, j], 0)
      GG[i, j] = fdiv(pres(), dof)
    }
  }
  return jacobi(GG, m, E)
}

function ezekiel(r2, n, m) {
  return 1.0 - fdiv((1.0 - r2) * (n - 1), n - 1 - m)
}

function clr(C, n, p, OUT,   i, j, ml, L) {
  for (i = 0; i < n; i++) {
    pinit()
    for (j = 0; j < p; j++) { L[j] = mlog(C[i, j]); padd(L[j], 0) }
    ml = fdiv(pres(), p)
    for (j = 0; j < p; j++) OUT[i, j] = L[j] - ml
  }
}

function hellinger(C, CI, n, p, OUT,   i, j, tot) {
  for (i = 0; i < n; i++) {
    pinit()
    for (j = 0; j < p; j++) padd(C[i, j], CI[i, j])
    tot = pres()
    for (j = 0; j < p; j++) OUT[i, j] = msqrt(fdiv(C[i, j], tot))
  }
}

# reference_linear_rda. Results go to R_* globals (rounded as in the Python)
# and U_* globals (unrounded, used by the numeric test driver only).
function rda(Y, YI, n, p, X, XI, kx, Z, ZI, kz, hasz,   i, j, dof, tot, cond, q, k, dfres, con, unc, r2, adj, f, r2xz, r2z, ne, nu, v) {
  if (n < 1) die("empty matrix")
  dof = n - 1
  centre(Y, YI, n, p, YC)
  centre(X, XI, n, kx, XC)
  tot = fdiv(frob_sq(YC, n, p), dof)
  cond = 0; q = 0
  for (i = 0; i < n; i++) for (j = 0; j < p; j++) YW[i, j] = YC[i, j]
  for (i = 0; i < n; i++) for (j = 0; j < kx; j++) XW[i, j] = XC[i, j]
  if (hasz) {
    centre(Z, ZI, n, kz, ZC)
    q = mgs(ZC, NOZ, n, kz, QZ)
    if (q > 0) {
      project(QZ, q, YW, n, p, YZ)
      cond = fdiv(frob_sq(YZ, n, p), dof)
      sub_mat(YW, YZ, n, p, YW)
      project(QZ, q, XW, n, kx, XZ)
      sub_mat(XW, XZ, n, kx, XW)
    }
  }
  k = mgs(XW, NOZ, n, kx, QX)
  dfres = n - 1 - q - k
  project(QX, k, YW, n, p, YH)
  sub_mat(YW, YH, n, p, YR)
  con = fdiv(frob_sq(YH, n, p), dof)
  unc = fdiv(frob_sq(YR, n, p), dof)
  r2 = fdiv(con, tot)
  if (q == 0) adj = ezekiel(r2, n, k)
  else {
    r2xz = fdiv(con + cond, tot)
    r2z = fdiv(cond, tot)
    adj = ezekiel(r2xz, n, k + q) - ezekiel(r2z, n, q)
  }
  f = fdiv(fdiv(con, k), fdiv(unc, dfres))
  delete R_CE; delete R_UE; delete U_CE; delete U_UE
  ne = gram_eigs(YH, n, p, dof, U_CE)
  for (i = 0; i < ne; i++) R_CE[i] = rnd(U_CE[i], 12)
  nu = gram_eigs(YR, n, p, dof, U_UE)
  for (i = 0; i < nu; i++) R_UE[i] = rnd(U_UE[i], 12)
  R_NCE = ne; R_NUE = nu
  R_adj = rnd(adj, 12); R_cond = rnd(cond, 12); R_con = rnd(con, 12)
  R_q = q; R_k = k; R_dfres = dfres
  R_f = rnd(f, 12); R_r2 = rnd(r2, 12); R_tot = rnd(tot, 12); R_unc = rnd(unc, 12)
  U_adj = adj; U_cond = cond; U_con = con; U_f = f; U_r2 = r2; U_tot = tot; U_unc = unc
}

# reference_varpart_twoway. Results in VP[name].
function varpart(Y, YI, n, p, X1, X1I, k1, X2, X2I, k2,   i, j, ra, rb, rab) {
  rda(Y, YI, n, p, X1, X1I, k1, NOZ, NOZ, 0, 0)
  ra = R_adj
  rda(Y, YI, n, p, X2, X2I, k2, NOZ, NOZ, 0, 0)
  rb = R_adj
  for (i = 0; i < n; i++) {
    for (j = 0; j < k1; j++) { X12[i, j] = X1[i, j]; X12I[i, j] = X1I[i, j] }
    for (j = 0; j < k2; j++) { X12[i, k1 + j] = X2[i, j]; X12I[i, k1 + j] = X2I[i, j] }
  }
  rda(Y, YI, n, p, X12, X12I, k1 + k2, NOZ, NOZ, 0, 0)
  rab = R_adj
  VP["gross_x1_adj_r2"] = rnd(ra, 12)
  VP["gross_x12_adj_r2"] = rnd(rab, 12)
  VP["gross_x2_adj_r2"] = rnd(rb, 12)
  VP["residual"] = rnd(1.0 - rab, 12)
  VP["shared"] = rnd(ra + rb - rab, 12)
  VP["unique_x1"] = rnd(rab - rb, 12)
  VP["unique_x2"] = rnd(rab - ra, 12)
}

# ---------------------------------------------------------- fixture checking

# Load a JSON matrix node into M and MI. Sets MN (rows) and MP (columns).
function loadmat(id, M, MI, what,   i, j, r, e) {
  delete M; delete MI
  if (T[id] != "a" || NK[id] < 1) die(what ": expected a non-empty array of rows")
  MN = NK[id]; MP = -1
  for (i = 1; i <= MN; i++) {
    r = KID[id, i]
    if (T[r] != "a" || NK[r] < 1) die(what ": row " i " is not a non-empty array")
    if (MP < 0) MP = NK[r]
    else if (NK[r] != MP) die(what ": ragged rows")
    for (j = 1; j <= MP; j++) {
      e = KID[r, j]
      if (T[e] != "i" && T[e] != "f") die(what ": non-numeric entry")
      M[i - 1, j - 1] = V[e]
      MI[i - 1, j - 1] = (T[e] == "i") ? 1 : 0
    }
  }
}

function needk(o, name, what,   id) {
  id = getk(o, name)
  if (!id) die(what ": missing key " name)
  return id
}

function numval(id, what) {
  if (T[id] != "i" && T[id] != "f") die(what ": expected a number")
  return V[id]
}

function check_dataset(d,   dsid, yn, y, tr, trs, rawn, i, j, mn, mp, z, zn, xn, key, keys, nk, a, b, ex_, k, vk, exv, ev, anum, enum_, isum, vpsum, parr_, nex, r) {
  if (T[d] != "o") die("dataset entry is not an object")
  dsid = D[needk(d, "id", "dataset")]
  y = needk(d, "y", dsid)
  loadmat(y, MY, MYI, dsid ".y"); YN = MN; YP = MP
  tr = getk(d, "transform")
  trs = (tr && T[tr] == "s") ? V[tr] : ""
  if (trs == "\"clr\"" || trs == "\"hellinger\"") {
    loadmat(needk(d, "raw_counts", dsid), MC, MCI, dsid ".raw_counts"); RN = MN; RP = MP
    if (trs == "\"clr\"") clr(MC, RN, RP, MR)
    else hellinger(MC, MCI, RN, RP, MR)
    for (i = 0; i < RN; i++) for (j = 0; j < RP; j++) MRI[i, j] = 0
    mn = RN; mp = RP
    # The stored matrix must have the shape of the one rebuilt from raw_counts.
    if (YN != RN || YP != RP) die(dsid ": stored transformed matrix has a different shape from raw_counts")
    a = RN; b = RP
    for (i = 0; i < a; i++) for (j = 0; j < b; j++)
      if (abs(MY[i, j] - MR[i, j]) > 1e-10) die(dsid ": stored transformed matrix drifted from raw_counts")
  } else {
    delete MR; delete MRI
    for (i = 0; i < YN; i++) for (j = 0; j < YP; j++) { MR[i, j] = MY[i, j]; MRI[i, j] = MYI[i, j] }
    mn = YN; mp = YP
  }
  loadmat(needk(d, "x", dsid), MX, MXI, dsid ".x"); xn = MN; MXP = MP
  if (xn != mn) die(dsid ": x row count differs from y")
  z = needk(d, "z", dsid)
  zn = 0
  if (T[z] != "N") {
    loadmat(z, MZ, MZI, dsid ".z"); zn = 1
    if (MN != mn) die(dsid ": z row count differs from y")
    MZP = MP
  }
  rda(MR, MRI, mn, mp, MX, MXI, MXP, MZ, MZI, MZP, zn)
  ex_ = needk(d, "expected_rda", dsid)
  if (T[ex_] != "o") die(dsid ": expected_rda is not an object")
  nk = split("total_inertia conditioned_inertia constrained_inertia unconstrained_inertia r2 adj_r2 f_statistic", keys, " ")
  RV["total_inertia"] = R_tot; RV["conditioned_inertia"] = R_cond; RV["constrained_inertia"] = R_con
  RV["unconstrained_inertia"] = R_unc; RV["r2"] = R_r2; RV["adj_r2"] = R_adj; RV["f_statistic"] = R_f
  for (i = 1; i <= nk; i++) {
    key = keys[i]
    ev = numval(needk(ex_, key, dsid ".expected_rda"), dsid "." key)
    if (abs(RV[key] - ev) > 1e-9) die(sprintf("%s.%s: expected %s, recomputed %s", dsid, key, ev, RV[key]))
  }
  for (k = 1; k <= 2; k++) {
    key = (k == 1) ? "constrained_eigenvalues" : "unconstrained_eigenvalues"
    parr_ = needk(ex_, key, dsid ".expected_rda")
    if (T[parr_] != "a") die(dsid "." key ": expected an array")
    nex = (k == 1) ? R_NCE : R_NUE
    if (nex != NK[parr_]) die(dsid "." key ": length mismatch")
    for (i = 0; i < nex; i++) {
      anum = (k == 1) ? R_CE[i] : R_UE[i]
      enum_ = numval(KID[parr_, i + 1], dsid "." key)
      if (abs(anum - enum_) > 1e-9) die(sprintf("%s.%s: %s != %s", dsid, key, anum, enum_))
    }
  }
  isum = R_cond + R_con + R_unc
  if (abs(R_tot - isum) > 1e-10) die(dsid ": inertia partition does not sum to total_inertia")
  vk = needk(d, "expected_varpart", dsid)
  if (T[vk] != "N") {
    if (T[vk] != "o") die(dsid ": expected_varpart is not an object")
    loadmat(needk(d, "x1", dsid), MX1, MX1I, dsid ".x1"); a = MN; MX1P = MP
    loadmat(needk(d, "x2", dsid), MX2, MX2I, dsid ".x2"); b = MN; MX2P = MP
    if (a != mn || b != mn) die(dsid ": x1 or x2 row count differs from y")
    varpart(MR, MRI, mn, mp, MX1, MX1I, MX1P, MX2, MX2I, MX2P)
    for (i = 1; i <= NK[vk]; i++) {
      # KEY holds the escaped, quoted form; strip the quotes for lookup
      key = KEY[vk, i]
      key = substr(key, 2, length(key) - 2)
      if (!(key in VP)) die(dsid ".varpart: unknown key " key)
      ev = numval(KID[vk, i], dsid ".varpart." key)
      if (abs(VP[key] - ev) > 1e-9) die(sprintf("%s.varpart.%s: expected %s, got %s", dsid, key, ev, VP[key]))
    }
    vpsum = VP["unique_x1"] + VP["unique_x2"] + VP["shared"] + VP["residual"]
    if (abs(vpsum - 1.0) > 1e-10) die(sprintf("%s: varpart fractions sum to %s, expected 1.0", dsid, vpsum))
  }
}

function verify_fixture_math(root,   ds, nds, i) {
  if (T[root] != "o") die("fixture root must be an object")
  ds = getk(root, "datasets")
  nds = 0
  if (ds) {
    if (T[ds] != "a") die("datasets must be an array")
    nds = NK[ds]
  }
  if (nds < 4) die("Expected >= 4 reference datasets, found " nds)
  for (i = 1; i <= nds; i++) check_dataset(KID[ds, i])
  return nds
}

# ------------------------------------------------------------- generation
# Builders for output trees.

function mkobj() { return newnode("o") }
function mkarr() { return newnode("a") }
function mknum(x,   id) { id = newnode("f"); V[id] = x; BAD[id] = ""; return id }
function mkint(x,   id) { id = newnode("i"); V[id] = x; BAD[id] = ""; return id }
function mknull() { return newnode("N") }
function mkstr(s,   id) {
  id = newnode("s")
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  V[id] = "\"" s "\""; D[id] = s; BAD[id] = ""
  return id
}
function apush(a, v) { NK[a]++; KID[a, NK[a]] = v }
function oset(o, name, v,   sk) {
  sk = askhex(name)
  addmember(o, "\"" name "\"", sk, "", v)
}

# Matrix as a node, rounding to d digits when d > 0.
function matnode(M, n, p, d,   a, r, i, j, x) {
  a = mkarr()
  for (i = 0; i < n; i++) {
    r = mkarr()
    for (j = 0; j < p; j++) {
      x = M[i, j]
      if (d > 0) x = rnd(x, d)
      apush(r, mknum(x))
    }
    apush(a, r)
  }
  return a
}

function rdanode(   o, a, i) {
  o = mkobj()
  oset(o, "adj_r2", mknum(R_adj))
  oset(o, "conditioned_inertia", mknum(R_cond))
  a = mkarr(); for (i = 0; i < R_NCE; i++) apush(a, mknum(R_CE[i]))
  oset(o, "constrained_eigenvalues", a)
  oset(o, "constrained_inertia", mknum(R_con))
  oset(o, "df_conditioned", mkint(R_q))
  oset(o, "df_model", mkint(R_k))
  oset(o, "df_residual", mkint(R_dfres))
  oset(o, "f_statistic", mknum(R_f))
  oset(o, "r2", mknum(R_r2))
  oset(o, "total_inertia", mknum(R_tot))
  a = mkarr(); for (i = 0; i < R_NUE; i++) apush(a, mknum(R_UE[i]))
  oset(o, "unconstrained_eigenvalues", a)
  oset(o, "unconstrained_inertia", mknum(R_unc))
  return o
}

function vpnode(   o, k) {
  o = mkobj()
  for (k in VP) oset(o, k, mknum(VP[k]))
  return o
}

# Fill M from rows "a b c;d e f". Sets MN, MP. Flags all zero (floats).
function parse_rows(str, M, MI,   rows, cols, nr, nc, i, j) {
  delete M; delete MI
  nr = split(str, rows, ";")
  for (i = 1; i <= nr; i++) {
    nc = split(rows[i], cols, " ")
    for (j = 1; j <= nc; j++) { M[i - 1, j - 1] = cols[j] + 0; MI[i - 1, j - 1] = 0 }
  }
  MN = nr; MP = nc
}

# Column vector from "a b c ...".
function parse_col(str, M, MI,   cols, n, i) {
  delete M; delete MI
  n = split(str, cols, " ")
  for (i = 1; i <= n; i++) { M[i - 1, 0] = cols[i] + 0; MI[i - 1, 0] = 0 }
  MN = n; MP = 1
}

function hcat(A, n, pa, B, pb, OUT,   i, j) {
  for (i = 0; i < n; i++) {
    for (j = 0; j < pa; j++) OUT[i, j] = A[i, j]
    for (j = 0; j < pb; j++) OUT[i, pa + j] = B[i, j]
  }
}

function build_reference_document(   doc, dss, ds, n, p, i, j) {
  # 1. Ecological benchmark: first 10 sites x 8 species of the vegan dune data
  parse_rows("1 0 0 0 0 0 0 0;3 0 0 2 0 3 4 0;0 4 0 7 0 2 0 0;0 8 0 2 0 2 3 0;2 0 0 0 4 2 2 0;2 0 0 0 3 0 0 0;2 0 0 0 2 0 2 0;0 4 0 5 0 0 0 0;0 3 0 3 0 0 0 1;4 0 0 0 4 2 4 0", DY, DYI)
  DN = MN; DP = MP
  parse_col("2.8 3.5 4.3 4.2 6.3 4.3 2.8 4.2 3.7 3.3", DA, DAI)
  parse_col("1 1 2 2 1 1 1 5 4 2", DM, DMI)
  hcat(DA, DN, 1, DM, 1, DX)
  # 2. Gut amplicon counts, CLR (Aitchison geometry)
  parse_rows("420 310 120 85 45 20;395 330 115 90 48 22;450 290 110 80 50 20;410 305 130 82 49 24;140 160 290 210 130 70;125 175 310 195 125 70;155 150 280 215 135 65;135 165 305 205 120 70;75 95 220 270 210 130;80 90 210 280 215 125;70 100 230 265 205 130;85 88 215 275 212 125", GC, GCI)
  GN = MN; GP = MP
  clr(GC, GN, GP, GY)
  parse_col("0 0 0 0 1 1 1 1 1 1 1 1", GA, GAI)
  parse_col("28 26 31 29 18 19 17 20 9 8 10 9.5", GF, GFI)
  hcat(GA, GN, 1, GF, 1, GX)
  # 3. Oral microbiome, CLR with Condition(batch) partial RDA
  parse_rows("500 250 120 70 40 20;480 270 115 72 42 21;520 240 110 68 41 21;190 180 260 190 110 70;205 175 250 195 108 67;185 185 268 188 106 68;310 380 150 85 50 25;295 395 155 80 52 23;320 370 148 86 49 27;110 240 310 185 95 60;118 232 305 190 97 58;105 248 315 180 92 60", OC, OCI)
  ON = MN; OP = MP
  clr(OC, ON, OP, OY)
  parse_col("0 0 0 1 1 1 0 0 0 1 1 1", OS, OSI)
  parse_col("0 0 0 0 0 0 1 1 1 1 1 1", OB, OBI)
  # 4. Marine Hellinger community across salinity, depth and interaction
  parse_rows("610 220 90 40 20 12 8;580 245 95 38 22 11 9;430 310 140 65 30 15 10;390 330 155 70 28 16 11;240 290 230 125 65 30 20;210 275 250 140 70 33 22;130 195 270 195 115 58 37;115 180 280 205 120 62 38;65 110 240 255 175 95 60;55 102 232 265 182 100 64", MC2, MC2I)
  MNN = MN; MPP = MP
  hellinger(MC2, MC2I, MNN, MPP, MY2)
  parse_col("30.1 30.4 31.8 32.1 33.5 33.9 34.8 35.0 35.7 36.0", MS, MSI)
  parse_col("5 8 15 18 35 42 75 85 140 160", MD, MDI)
  for (i = 0; i < MNN; i++) { MX3[i, 0] = MS[i, 0]; MX3[i, 1] = MD[i, 0]; MX3[i, 2] = MS[i, 0] * MD[i, 0] }
  for (i = 0; i < MNN; i++) for (j = 0; j < 3; j++) MX3I[i, j] = 0

  doc = mkobj()
  dss = mkarr()

  ds = mkobj()
  oset(ds, "description", mkstr("vegan dune meadow 10-site x 8-species benchmark with A1 and Moisture"))
  rda(DY, DYI, DN, DP, DX, DYI, 2, NOZ, NOZ, 0, 0); oset(ds, "expected_rda", rdanode())
  varpart(DY, DYI, DN, DP, DA, DAI, 1, DM, DMI, 1); oset(ds, "expected_varpart", vpnode())
  oset(ds, "id", mkstr("dune_meadow_subset"))
  oset(ds, "x", matnode(DX, DN, 2, 10))
  oset(ds, "x1", matnode(DA, DN, 1, 0))
  oset(ds, "x2", matnode(DM, DN, 1, 0))
  oset(ds, "y", matnode(DY, DN, DP, 0))
  oset(ds, "z", mknull())
  apush(dss, ds)

  ds = mkobj()
  oset(ds, "description", mkstr("Gut microbiome 12-sample x 6-taxon CLR (Aitchison) ordination across antibiotic exposure and fibre"))
  rda(GY, GCI, GN, GP, GX, GCI, 2, NOZ, NOZ, 0, 0); oset(ds, "expected_rda", rdanode())
  varpart(GY, GCI, GN, GP, GA, GAI, 1, GF, GFI, 1); oset(ds, "expected_varpart", vpnode())
  oset(ds, "id", mkstr("microbiome_gut_clr_antibiotic"))
  oset(ds, "raw_counts", matnode(GC, GN, GP, 0))
  oset(ds, "transform", mkstr("clr"))
  oset(ds, "x", matnode(GX, GN, 2, 0))
  oset(ds, "x1", matnode(GA, GN, 1, 0))
  oset(ds, "x2", matnode(GF, GN, 1, 0))
  oset(ds, "y", matnode(GY, GN, GP, 12))
  oset(ds, "z", mknull())
  apush(dss, ds)

  ds = mkobj()
  oset(ds, "description", mkstr("Oral microbiome 12-sample x 6-taxon partial CLR RDA with Condition(batch)"))
  rda(OY, OCI, ON, OP, OS, OSI, 1, OB, OBI, 1, 1); oset(ds, "expected_rda", rdanode())
  oset(ds, "expected_varpart", mknull())
  oset(ds, "id", mkstr("microbiome_oral_partial_batch"))
  oset(ds, "raw_counts", matnode(OC, ON, OP, 0))
  oset(ds, "transform", mkstr("clr"))
  oset(ds, "x", matnode(OS, ON, 1, 0))
  oset(ds, "y", matnode(OY, ON, OP, 12))
  oset(ds, "z", matnode(OB, ON, 1, 0))
  apush(dss, ds)

  ds = mkobj()
  oset(ds, "description", mkstr("Marine microbiome 10-sample x 7-taxon Hellinger RDA with salinity, depth, and interaction"))
  rda(MY2, MC2I, MNN, MPP, MX3, MX3I, 3, NOZ, NOZ, 0, 0); oset(ds, "expected_rda", rdanode())
  varpart(MY2, MC2I, MNN, MPP, MS, MSI, 1, MD, MDI, 1); oset(ds, "expected_varpart", vpnode())
  oset(ds, "id", mkstr("microbiome_marine_salinity_depth"))
  oset(ds, "raw_counts", matnode(MC2, MNN, MPP, 0))
  oset(ds, "transform", mkstr("hellinger"))
  oset(ds, "x", matnode(MX3, MNN, 3, 10))
  oset(ds, "x1", matnode(MS, MNN, 1, 0))
  oset(ds, "x2", matnode(MD, MNN, 1, 0))
  oset(ds, "y", matnode(MY2, MNN, MPP, 12))
  oset(ds, "z", mknull())
  apush(dss, ds)

  oset(doc, "datasets", dss)
  oset(doc, "schema_version", mkstr("1.0.0"))
  oset(doc, "tolerance", mknum(0.000001))
  return doc
}

# The schema source is plain JSON read from ORD_SCHEMA_SRC. Its key order does
# not matter: the JCS serialiser sorts it.
function build_schema_document(   text) {
  text = slurp(ENVIRON["ORD_SCHEMA_SRC"])
  return parse_json(text)
}

function write_file(path, s) {
  printf "%s\n", s > path
  close(path)
}

function do_generate(   doc, sch) {
  sch = build_schema_document()
  write_file(ENVIRON["ORD_SCHEMA_OUT"], jcs(sch))
  doc = build_reference_document()
  write_file(ENVIRON["ORD_FIXTURE_OUT"], jcs(doc))
}

function do_check(   fix, nds) {
  check_oracle(ENVIRON["ORD_ORACLE"])
  verify_kyaml(ENVIRON["ORD_KYAML"])
  verify_jcs_file(ENVIRON["ORD_SCHEMA"], ENVIRON["ORD_SCHEMA_LF"] == "1")
  fix = verify_jcs_file(ENVIRON["ORD_FIXTURE"], ENVIRON["ORD_FIXTURE_LF"] == "1")
  nds = verify_fixture_math(fix)
  printf "OK: verified %d ordination reference datasets, JCS schema (%s), and KYAML contract (%s).\n", nds, ENVIRON["ORD_SCHEMA_NAME"], ENVIRON["ORD_KYAML_NAME"]
}

BEGIN {
  init_tables()
  if (ENVIRON["ORD_LIB"] == "") {
    if (ENVIRON["ORD_STAGE"] == "generate") do_generate()
    else do_check()
  }
}
