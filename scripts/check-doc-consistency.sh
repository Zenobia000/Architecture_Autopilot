#!/usr/bin/env bash
# check-doc-consistency.sh — 跨文件「同物不同畫」一致性 linter
#
# 補 devteam 盲區：persona critique 驗領域品質，不驗跨文件 ID/顆粒度/命名一致。
# 本 linter 機械檢查那條軸。可手跑、可掛 pre-commit / CI。任一 critical 失敗 → exit 1。
#
# 通用模板原則：本 script 不含任何 feature 名 / ID 文法 / 格式字面值。
#   所有可枚舉事實讀 devteam_knowledge_base/_registry.json（gates / id_patterns /
#   header_standard / feature_bindings）。改規則先改 registry，不改本檔。
#
# 兩類檢查：
#   結構軸（KB / registry / agents）— 永遠跑，與 session 無關。
#   session 軸（docs/ + .claude/context/devteam/）— 僅在 active session 存在時跑；
#     模板狀態（feature_bindings={}、無 docs/、無 state.json）一律 ⊘ SKIP，不誤判為 fail。
#
# 用法： scripts/check-doc-consistency.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$ROOT/docs"
DEVDOC="$ROOT/.claude/context/devteam/documents"
STATE="$ROOT/.claude/context/devteam/state.json"
REG="$ROOT/devteam_knowledge_base/_registry.json"
FAIL=0
pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip(){ echo "  ⊘ SKIP: $1"; }
absorb(){ # 收 python RESULT n → 併入 FAIL（python 已自印 ✓/✗/⊘ 行）
  local out="$1"; echo "$out" | grep -v "^RESULT" | sed 's/^//'
  local n; n=$(echo "$out" | grep "^RESULT" | awk '{print $2}'); FAIL=$((FAIL + ${n:-1}))
}

[ -d "$DOCS" ]              && HAVE_DOCS=1  || HAVE_DOCS=0
[ -f "$DEVDOC/index.json" ] && HAVE_INDEX=1 || HAVE_INDEX=0
[ -f "$STATE" ]            && HAVE_STATE=1 || HAVE_STATE=0

echo "== C1 斷連結（docs/ 相對連結指向不存在的檔）=="
if [ "$HAVE_DOCS" = 0 ]; then skip "無 docs/（模板狀態，無 active session）"; else
  broken=0
  while IFS= read -r f; do
    dir=$(dirname "$f")
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      tgt=$(cd "$dir" && realpath -m "$rel" 2>/dev/null)
      [ -e "$tgt" ] || { echo "    broken: ${f#$ROOT/} -> $rel"; broken=$((broken+1)); }
    done < <(grep -oE "\]\((\.\.?/[^)#]+\.(md|sql|yaml|yml))" "$f" 2>/dev/null | sed -E 's/^\]\(//')
  done < <(find "$DOCS" -name "*.md")
  [ "$broken" -eq 0 ] && pass "無斷連結" || fail "$broken 個斷連結"
fi

echo "== C3 ADR 佔位殘留（registry.id_patterns.adr_placeholder 應已落地為實體 ADR）=="
if [ "$HAVE_DOCS" = 0 ]; then skip "無 docs/（模板狀態）"; else
absorb "$(python3 - "$ROOT" <<'PY'
import json,re,sys,glob,os
root=sys.argv[1]; reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
ph=reg["id_patterns"]["adr_placeholder"]; resolved=reg["id_patterns"]["adr_resolved_ref"]
fails=0
for fp in sorted(glob.glob(f"{root}/docs/**/*.md",recursive=True)):
    for i,ln in enumerate(open(fp,encoding="utf-8"),1):
        if re.search(ph,ln) and not re.search(resolved,ln):
            print(f"    {os.path.relpath(fp,root)}:{i}: {ln.strip()}"); fails+=1
print("  ✗ FAIL: ADR 佔位殘留（須落地）" if fails else "  ✓ 無 ADR 佔位殘留")
print(f"RESULT {1 if fails else 0}")
PY
)"
fi

echo "== C5 index.json ↔ .meta.json parity =="
if [ "$HAVE_INDEX" = 0 ]; then skip "無 index.json（模板狀態）"; else
absorb "$(python3 - "$DEVDOC" <<'PY'
import json,os,sys
base=sys.argv[1]; idx=json.load(open(f"{base}/index.json")); miss=0
for p in idx:
    if not os.path.exists(f"{base}/"+p.replace("/","__")+".meta.json"): print("    缺 meta:",p); miss+=1
print(f"  ✓ {len(idx)} 條目全有 .meta.json" if miss==0 else f"  ✗ FAIL: {miss} 個 index 條目缺 .meta.json")
print(f"RESULT {1 if miss else 0}")
PY
)"
fi

echo "== C2/C4/C6/C7/C8 feature-scoped 檢查（讀 registry.feature_bindings；空則全 skip）=="
absorb "$(python3 - "$ROOT" <<'PY'
import json,re,sys,os,glob
root=sys.argv[1]; reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
feats=reg.get("feature_bindings",{}); P=reg["id_patterns"]
FR=P["functional_requirement"]; UC=P["use_case"]; UCH=P["use_case_heading"]
SEC=P["security_test"]; TMROW=P["threat_row"]
fails=0
def rd(p):
    fp=f"{root}/{p}"; return open(fp,encoding="utf-8").read() if os.path.exists(fp) else None
def hdr(c): print(f"  -- {c}")

if not feats:
    for c in ("C2 改名死連結","C4 TC-SEC 跨文件 parity","C6 STRIDE→測試覆蓋","C7 orphan FR","C8 dangling UC"):
        hdr(c); print("  ⊘ SKIP: feature_bindings 空（通用模板，無 active feature）")
    print("RESULT 0"); sys.exit(0)

# C2 改名死連結（每 feature 的 dead_path_patterns 不應現身任何 docs）
hdr("C2 改名死連結")
docs=[fp for fp in glob.glob(f"{root}/docs/**/*.md",recursive=True)]
c2=0
for feat,b in feats.items():
    pats=b.get("dead_path_patterns",[])
    if not pats: continue
    for fp in docs:
        txt=open(fp,encoding="utf-8").read()
        for pat in pats:
            if re.search(pat,txt): print(f"    [{feat}] {os.path.relpath(fp,root)} 含死路徑 /{pat}/"); c2+=1
fails+=c2
print("  ✓ 無改名死連結" if c2==0 else f"  ✗ FAIL: {c2} 個死路徑殘留")

# C4 TC-SEC 跨文件 parity（threat_model 與 test_plan 提到的每個 TC-SEC 須兩邊都有）
hdr("C4 TC-SEC 跨文件 parity")
c4=0; ran4=False
for feat,b in feats.items():
    tm=rd((b.get("docs") or {}).get("threat_model","")); tp=rd((b.get("gates") or {}).get("Gate6_TestReady",""))
    if tm is None or tp is None: print(f"    [{feat}] ⊘ skip：無 threat_model / test_plan"); continue
    ran4=True
    ids=set(re.findall(SEC,tm))|set(re.findall(SEC,tp))
    for sid in sorted(ids):
        intm=sid in re.findall(SEC,tm); intp=sid in re.findall(SEC,tp)
        if intm and intp: print(f"    [{feat}] {sid} 兩文件皆有")
        else: print(f"    [{feat}] ✗ {sid} 缺（threat_model={intm} test_plan={intp}）"); c4+=1
fails+=c4
print("  ✓ TC-SEC 跨文件一致" if c4==0 else f"  ✗ FAIL: {c4} 個 TC-SEC parity 缺口") if ran4 else None

# C6 STRIDE→測試覆蓋（threat_model 每條 TM-row 須引用一個 TC-SEC）
hdr("C6 STRIDE→測試覆蓋")
c6=0; ran6=False
for feat,b in feats.items():
    tm=rd((b.get("docs") or {}).get("threat_model",""))
    if tm is None: print(f"    [{feat}] ⊘ skip：無 threat_model"); continue
    ran6=True
    for ln in tm.splitlines():
        if re.search(TMROW,ln) and not re.search(SEC,ln):
            print(f"    [{feat}] ✗ TM-row 無對應 TC-SEC: {ln.strip()[:60]}"); c6+=1
fails+=c6
print("  ✓ 每條 STRIDE 威脅皆有對抗測試" if c6==0 else f"  ✗ FAIL: {c6} 條 STRIDE 威脅無測試") if ran6 else None

# C7 orphan FR（PRD 的 FR 須現身 traceability_matrix）
hdr("C7 orphan FR")
c7=0; ran7=False
for feat,b in feats.items():
    prd=rd((b.get("gates") or {}).get("Gate1_PRD","")); mtx=rd((b.get("docs") or {}).get("traceability_matrix",""))
    if prd is None or mtx is None: print(f"    [{feat}] ⊘ skip：無 prd / traceability_matrix"); continue
    ran7=True
    for fr in sorted(set(re.findall(FR,prd))):
        if fr not in mtx: print(f"    [{feat}] ✗ orphan: {fr} 不在 matrix"); c7+=1
fails+=c7
print("  ✓ 所有 FR 都在 traceability-matrix" if c7==0 else f"  ✗ FAIL: {c7} 個 orphan FR") if ran7 else None

# C8 dangling UC（system_spec 引用的 UC 須有對應定義 heading）
hdr("C8 dangling UC")
c8=0; ran8=False
def ucnum(s): m=re.search(r"UC-0*(\d+)",s); return m.group(1) if m else None
for feat,b in feats.items():
    spec=rd((b.get("gates") or {}).get("Gate3_SystemSpec",""))
    if spec is None: print(f"    [{feat}] ⊘ skip：無 system_spec"); continue
    ran8=True
    defined={m for ln in spec.splitlines() if (m:=( re.search(UCH,ln) and re.search(r"UC-0*(\d+)",ln).group(1)))}
    referenced={n for s in re.findall(UC,spec) if (n:=ucnum(s))}
    for n in sorted(referenced-defined,key=int):
        print(f"    [{feat}] ✗ dangling: UC-{n} 被引用但無定義 heading"); c8+=1
fails+=c8
print("  ✓ 無 dangling UC 引用" if c8==0 else f"  ✗ FAIL: {c8} 個 dangling UC") if ran8 else None

print(f"RESULT {fails}")
PY
)"

echo "== C9 gate ↔ doc Status 同步（frozen gate ⟹ doc Status∈{frozen,reviewed}；blocked 不誤殺）=="
if [ "$HAVE_STATE" = 0 ] || [ "$HAVE_INDEX" = 0 ]; then skip "無 state.json / index.json（模板狀態）"; else
absorb "$(python3 - "$ROOT" <<'PY'
import json,re,sys,os
root=sys.argv[1]
state=json.load(open(f"{root}/.claude/context/devteam/state.json"))
gates=state.get("freeze_gates",{})
idx=json.load(open(f"{root}/.claude/context/devteam/documents/index.json"))
reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
feat=(state.get("active_features") or [None])[0]
owner=((reg.get("feature_bindings",{}).get(feat) or {}).get("gates",{})) if feat else {}
def doc_status(p):
    if p.endswith(".yaml"): return idx.get(p,{}).get("status","")
    fp=f"{root}/{p}"
    if not os.path.exists(fp): return None
    head="\n".join(open(fp,encoding="utf-8").read().splitlines()[:12])
    m=re.search(r"Status\*?\*?:\s*([A-Za-z]+)",head)
    return m.group(1) if m else ""
fails=0
for g,st in gates.items():
    doc=owner.get(g)
    if not doc: continue
    ds=doc_status(doc)
    if st=="frozen":
        if ds not in ("frozen","reviewed"): print(f"    gate {g}=frozen 但 {doc} Status={ds!r}（須 frozen/reviewed）"); fails+=1
    elif ds=="frozen": print(f"    {doc} Status=frozen 但 gate {g}={st}（gate 未 frozen）"); fails+=1
print("  ✓ frozen gate 與 doc Status 一致" if fails==0 else f"  ✗ FAIL: {fails} 個 gate↔Status 不一致")
print(f"RESULT {fails}")
PY
)"
fi

echo "== C10 KB-12 Universal Header（讀 registry.header_standard；豁免 foundation/README）=="
if [ "$HAVE_DOCS" = 0 ]; then skip "無 docs/（模板狀態）"; else
absorb "$(python3 - "$ROOT" <<'PY'
import os,sys,glob,re,json
root=sys.argv[1]; reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
H=reg["header_standard"]; pills=H["required_pills"]; linkany=H["link_pill_any_of"]
ok=set(H["status_enum"]); exd=tuple(H["exempt_dirs"]); exf=tuple(H["exempt_files"])
fails=0
for fp in sorted(glob.glob(f"{root}/docs/**/*.md",recursive=True)):
    rel=os.path.relpath(fp,root)
    if rel.startswith(exd) or rel in exf: continue
    head="\n".join(open(fp,encoding="utf-8").read().splitlines()[:14])
    miss=[p for p in pills if p not in head]
    if not any(p in head for p in linkany): miss.append("/".join(linkany))
    if miss: print(f"    {rel} 缺 pill: {' '.join(miss)}"); fails+=1; continue
    m=re.search(r"Status\*?\*?:\s*([A-Za-z]+)",head)
    if m and m.group(1) not in ok: print(f"    {rel} Status 值非法: {m.group(1)}"); fails+=1
print("  ✓ spec 文件 header 皆合 KB-12" if fails==0 else f"  ✗ FAIL: {fails} 份 header 不合格")
print(f"RESULT {fails}")
PY
)"
fi

echo "== C11 ASCII 框圖殘留（讀 registry.header_standard.ascii_box_chars；phase 文件應全 mermaid）=="
if [ "$HAVE_DOCS" = 0 ]; then skip "無 docs/（模板狀態）"; else
absorb "$(python3 - "$ROOT" <<'PY'
import os,sys,glob,re,json
root=sys.argv[1]; reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
H=reg["header_standard"]; box=re.compile(H["ascii_box_chars"]); exd=tuple(H["exempt_dirs"]); exf=tuple(H["exempt_files"])
fails=0
for fp in sorted(glob.glob(f"{root}/docs/**/*.md",recursive=True)):
    rel=os.path.relpath(fp,root)
    if rel.startswith(exd) or rel in exf: continue
    for i,ln in enumerate(open(fp,encoding="utf-8"),1):
        if box.search(ln): print(f"    {rel}:{i}: {ln.strip()[:60]}"); fails+=1
print("  ✓ phase 文件無 ASCII 框圖" if fails==0 else f"  ✗ FAIL: {fails} 處 ASCII 框圖（應轉 mermaid）")
print(f"RESULT {fails}")
PY
)"
fi

echo "== C12 index ↔ docs 雙向 parity =="
if [ "$HAVE_INDEX" = 0 ] || [ "$HAVE_DOCS" = 0 ]; then skip "無 index.json / docs/（模板狀態）"; else
absorb "$(python3 - "$ROOT" <<'PY'
import json,os,sys,glob
root=sys.argv[1]; reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
idx=json.load(open(f"{root}/.claude/context/devteam/documents/index.json"))
H=reg["header_standard"]; exd=tuple(H["exempt_dirs"]); exf=tuple(H["exempt_files"])
fails=0
for p in idx:
    if not os.path.exists(f"{root}/{p}"): print(f"    index 登記但檔不存在: {p}"); fails+=1
for fp in sorted(glob.glob(f"{root}/docs/**/*.md",recursive=True)):
    rel=os.path.relpath(fp,root)
    if rel.startswith(exd) or rel in exf: continue
    if rel not in idx: print(f"    docs 有檔但未登記 index: {rel}"); fails+=1
print("  ✓ index ↔ docs 雙向 parity 一致" if fails==0 else f"  ✗ FAIL: {fails} 個 parity 缺口")
print(f"RESULT {fails}")
PY
)"
fi

echo "== C13 _registry.json ↔ KB/state/agents 一致（防 KB-to-KB 漂移 HB-1）=="
absorb "$(python3 - "$ROOT" <<'PY'
import json,re,sys,os
root=sys.argv[1]; reg=json.load(open(f"{root}/devteam_knowledge_base/_registry.json"))
fails=0; skipped=[]
# C13a: registry gate IDs == state.json freeze_gates keys（需 state.json）
state_fp=f"{root}/.claude/context/devteam/state.json"
if os.path.exists(state_fp):
    state=json.load(open(state_fp))
    rg_gates=set(reg["gates"]); st_gates=set(state.get("freeze_gates",{}))
    if rg_gates!=st_gates: print(f"    [C13a] registry gates {sorted(rg_gates)} ≠ state freeze_gates {sorted(st_gates)}"); fails+=1
else: skipped.append("C13a(gates↔state)")
# C13b: 每 gate 的 required_diagrams 須現身 KB-04 對應 gate 段
kb04=open(f"{root}/devteam_knowledge_base/04_freeze_gates.md",encoding="utf-8").read()
parts=re.split(r"\n## Gate (\S+?):",kb04)
labelmap={"1":"Gate1_PRD","2":"Gate2_UXFlow","3":"Gate3_SystemSpec","4":"Gate4_NFR_ADR",
          "5a":"Gate5a_API","5b":"Gate5b_DBSchema","6":"Gate6_TestReady","7":"Gate7_Release"}
secs={}
for i in range(1,len(parts),2):
    gid=labelmap.get(parts[i].strip())
    if gid: secs[gid]=parts[i+1] if i+1<len(parts) else ""
for gid,gd in reg["gates"].items():
    for dia in gd.get("required_diagrams",[]):
        kw=reg["diagrams"].get(dia,{}).get("kb04_keyword",dia)
        if not re.search(kw,secs.get(gid,"")): print(f"    [C13b] {gid} 須畫 {dia} 但 KB-04 無 /{kw}/"); fails+=1
# C13c: feature_bindings 的 gates + docs 路徑須存在（空 bindings = no-op）
for feat,b in reg.get("feature_bindings",{}).items():
    for gid,doc in (b.get("gates") or {}).items():
        if not os.path.exists(f"{root}/{doc}"): print(f"    [C13c] {feat}.gates[{gid}] 指向不存在的檔: {doc}"); fails+=1
    for k,doc in (b.get("docs") or {}).items():
        if not os.path.exists(f"{root}/{doc}"): print(f"    [C13c] {feat}.docs[{k}] 指向不存在的檔: {doc}"); fails+=1
# C13d: registry roles 每 persona 須有 agent 檔
for p in reg["roles"]:
    if not os.path.exists(f"{root}/.claude/agents/devteam-{p}-persona.md"):
        print(f"    [C13d] role {p} 無對應 agent: .claude/agents/devteam-{p}-persona.md"); fails+=1
if skipped: print("    ⊘ "+", ".join(skipped)+" — 無 state.json（模板狀態）")
print("  ✓ registry ↔ KB-04 / state / agents 一致" if fails==0 else f"  ✗ FAIL: {fails} 個 registry 漂移")
print(f"RESULT {fails}")
PY
)"

echo ""
if [ "$FAIL" -eq 0 ]; then echo "✅ 全部一致性檢查通過（$FAIL fail）"; exit 0
else echo "❌ $FAIL 項一致性檢查失敗"; exit 1; fi
