# DevTeam Persona Voice Profile 系統設計

**Date**: 2026-05-22
**Status**: Approved (brainstorming complete, ready for implementation plan)
**Scope**: `.claude/agents/devteam-*-persona.md` × 12 + `.claude/skills/devteam-*/SKILL.md` × 7

---

## 1. 背景與問題

### 1.1 現況診斷

12 個 persona critique agent 的 prompt 骨架完全一致（視角邊界 / 任務 / 嚴禁 / blocker 範例），輸出 markdown 模板逐字相同（`### 重大阻礙 / 建議調整 / 通過項 / 衝突點`）。Domain knowledge 換了，但「講話的人」是同一個 LLM。

driver skill（devteam-pm / devteam-arch / ...）寫正式文件（PRD / ADR / OpenAPI / Test Plan / Runbook）時同樣缺乏角色語言指紋。

### 1.2 業主目標

每個角色的 critique 與正式文件「讀起來像不同的人寫的」。
換位思考 = 站在該角色的習慣詞彙、衡量單位、口吻產出文字。

### 1.3 不目標

- 不重新設計 persona 領域邊界（視角分工保持現狀）
- 不改 freeze gate / lane A/B/C 流程
- 不引入 LLM persona role-play 模式（avoid cosplay）
- 不動 output markdown structure（critique 模板不變，只變字句風格）

---

## 2. 設計

### 2.1 檔案位置與骨架

新增單一 source of truth：

```
devteam_knowledge_base/
  voice-profiles.md          ← 新增
```

骨架：

```markdown
# DevTeam Voice Profiles

## 全局規則
（anti-caricature 護欄 + 載入 protocol）

## persona: pm
- vocab: ...
- tone: ...
- taboo: ...
- frame: ...
- example:
  - before: ...
  - after: ...

## persona: po
...

（共 12 段）
```

### 2.2 Schema — 每個 persona 五欄位

| 欄位 | 內容 | 範例（PM） |
|:--|:--|:--|
| `vocab` | 5-8 個高頻慣用詞 / 縮寫 | KPI、counter-metric、scope creep、OKR、stakeholder、out-of-scope |
| `tone` | 一句話描述語氣 | 商業衡量、連 ROI、避免技術行話 |
| `taboo` | 3-5 個跨域忌諱詞 | lock contention、blast radius、WCAG |
| `frame` | 衡量事情的單位 | 使用者數 / 營收 / OKR 對齊度 |
| `example` | before（中性 LLM）vs after（該角色口吻）一組對照 | before:「KPI 不夠好」/ after:「KPI 缺數值與週期，且沒對應 counter-metric」 |

每個 persona 段約 200-400 字。12 persona 總計 voice-profiles.md ~3000-4500 字。

### 2.3 12 Persona 分配（對應現有 agent）

| Persona | Frame | Vocab 例 |
|:--|:--|:--|
| pm | 營收 / OKR / 使用者數 | KPI、counter-metric、scope、stakeholder、OKR |
| po | Backlog 優先序 / ready 條件 | priority、ready、ownership、DoD、capacity |
| ba | 業務規則 / 合規 | business rule、edge case、compliance、stakeholder map |
| sa | Use case / acceptance | use case、acceptance criteria、edge case、event flow |
| ux | Task success / state coverage | flow、state、journey、friction、a11y |
| ui | Component state / token | token、variant、breakpoint、density、handoff |
| arch | NFR / boundary / failure modes | bounded context、coupling、blast radius、ADR、NFR |
| sd | API / error model | endpoint、contract、idempotent、error model、telemetry |
| dba | Migration / PII / index | migration、backfill、PITR、PII、lock contention、index |
| qa | Test level / exit criteria | test pyramid、exit criteria、negative test、coverage |
| devops | Pipeline / rollback | pipeline gate、rollback、drift、artifact、promotion |
| sre | SLO / error budget | SLI、SLO、error budget、MTTR、postmortem |

### 2.4 Runtime 載入機制

#### 2.4.1 Persona agent（12 個）

每個 `.claude/agents/devteam-<role>-persona.md` 在「## 視角邊界」之前插入：

```markdown
## Voice

**開場必做**：Read `devteam_knowledge_base/voice-profiles.md` 找到 `## persona: <role>` 段。
寫 critique 時遵守該段 `vocab` / `tone` / `frame`，避開 `taboo` 詞，參考 `example` 對照口吻。
```

#### 2.4.2 Driver skill（7 個）

每個 `.claude/skills/devteam-<phase>/SKILL.md` 在「## 任務」之前插入：

```markdown
## Voice

**開場必做**：Read `devteam_knowledge_base/voice-profiles.md` 找到主筆角色段。
本 driver 主筆角色：<主筆 list>
寫文件時遵守該段口吻。跨角色內容（其他 persona 視角）以 critique / sidebar 方式注入，不混筆。
```

主筆對照：

| Driver Skill | 主筆 Persona |
|:--|:--|
| devteam-pm | pm |
| devteam-analyst | ba + sa（兩段都讀，BA 段寫 business rules，SA 段寫 use cases） |
| devteam-ux | ux + ui |
| devteam-arch | arch |
| devteam-design | sd + dba |
| devteam-qa | qa |
| devteam-ops | devops + sre |

### 2.5 Anti-caricature 護欄

寫進 voice-profiles.md 開頭「全局規則」段：

- **Vocab 預算**：每份 critique 用該 persona vocab 詞 ≤ 5 個（防「PM 每句話 OKR」）
- **Substance > voice**：finding 內容不能被口吻包裝模糊掉
- **Cross-frame ban**：用自己 frame 衡量，但不否定其他 persona 的 frame（PM 不該說「SRE 講 SLO 是錯的」）
- **No-cosplay clause**：voice profile 是「該角色慣用語」不是「該角色人格」。不戴假面具講話。

### 2.6 跨角色文件處理規則

像 Test Plan（QA 主筆，但 SD/SRE 都會評）這種文件：
1. 主筆 persona 口吻寫主體
2. 其他視角內容放 `### 跨視角備註` 區塊，明標來源 persona（例如 `> [SRE 視角]`）
3. 不在同一段落混兩種口吻

---

## 3. 遷移計畫

### 3.1 Pilot 階段（先動三個對比最強的）

選 PM / DBA / UX — 三個 frame 與 vocab 重疊最少，最容易驗證效果。

**步驟**：
1. 寫 `devteam_knowledge_base/voice-profiles.md`（含全局規則 + PM/DBA/UX 三段）
2. 改 `.claude/agents/devteam-pm-persona.md`、`devteam-dba-persona.md`、`devteam-ux-persona.md` 加 Voice 段
3. 改 `.claude/skills/devteam-pm/SKILL.md`、`devteam-design/SKILL.md`、`devteam-ux/SKILL.md` 加 Voice 段
4. 跑一次 `/devteam-review` 於既有 PRD 或 UX 文件，觀察 3 角色 critique 口吻差異
5. 業主驗收

**Pilot 驗收標準**：盲測同份 PRD 的 PM/DBA/UX critique，業主能從文字風格猜中 ≥ 2/3 角色。

### 3.2 Rollout 階段

Pilot 通過後一次補完：
- 剩下 9 個 persona agent：po / ba / sa / ui / arch / sd / qa / devops / sre
- 剩下 4 個 driver skill：devteam-analyst / devteam-arch / devteam-qa / devteam-ops

最終驗收：盲測同份 PRD 多角色 critique，業主猜中 ≥ 67%（8/12）。

---

## 4. Trade-off 與風險

### 4.1 已知 cost

- 每次 sub-agent dispatch 多一次 Read（voice-profiles.md ~3-5KB）
- 19 個檔加 5-10 行 voice 段，純加段不破壞既有結構
- voice-profiles.md 是單點，損毀 → 全 broken（但檔在 git，rollback 容易）

### 4.2 風險與緩解

| 風險 | 緩解 |
|:--|:--|
| Caricature（口吻變誇張表演） | Anti-caricature 護欄 + pilot 盲測 |
| Voice 蓋過 substance（finding 被包裝失焦） | 護欄第二條 + critique 模板不變 |
| 業主嫌不夠濃 / 太濃 | Pilot 後可調 schema 濃度（淡 ↔ 濃三檔） |
| Sub-agent 沒照做 Read | 改成 prompt 第一句強制 instruction；critique 出來明顯不對勁就 retrigger |

### 4.3 可調整點（未來迭代）

- 加 voice-profiles.md 開頭「跨 persona 對照表」（同一個概念 12 角色怎麼講）
- example 從 1 組擴到 2-3 組
- 加 per-persona 「sentence opener bank」（常用開場句型 5-10 句）

---

## 5. 不在本 spec 範圍

- Lane B（Forum-Lite）proposer/facilitator/critic 是否套 voice → 留下一輪
- Roundtable（Lane C）MoM 是否套主席口吻 → 留下一輪
- voice-profiles 國際化（英文版） → 留下一輪
- 自動化 voice 驗證腳本（nlp regex 檢查 taboo 詞） → 留下一輪

---

## 6. 完成定義（Done）

- [ ] `devteam_knowledge_base/voice-profiles.md` 含全局規則 + 12 persona 段
- [ ] 12 個 persona agent 加 Voice 段
- [ ] 7 個 driver skill 加 Voice 段
- [ ] Pilot 盲測通過（PM/DBA/UX ≥ 2/3 命中）
- [ ] 最終驗收通過（12 persona ≥ 67% 命中）
- [ ] `.claude/CLAUDE.md` 「Skill 使用規則」段補一句指向 voice-profiles
