# Ari IME 功能盤點與跨平台復刻規格

> 盤點基準：Ari IME 2.6.2（原始碼、測試、README、CHANGELOG 與已知限制）
>
> 文件目的：讓另一個專案在不依賴 Linux／Fcitx5 UI 的前提下，重做相同的輸入體驗。
>
> 狀態標記：本文的「必須」表示目前已有的行為；「建議」表示復刻時的架構建議，不是原專案的新功能承諾。

## 1. 產品定位

Ari IME 是繁體中文注音輸入法。它最重要的差異不是字典，而是「英文優先顯示、完整注音才轉中文」的混合輸入狀態機：

- 不需要手動切換中英文，就能在同一段未送出文字中混合中文、英文、數字與標點。
- 每個按鍵先以原始字元顯示；只有按鍵能組成「完整、有聲調、且真的查得到漢字」的注音音節時才轉成中文。
- 整段文字留在 pre-edit 中，只有 Enter 會送給應用程式。
- 中文轉換、組詞、候選排序與個人詞頻由 libchewing 提供；Ari 自己負責混輸判定、編輯、候選整合、標點、學習權重與前端橋接。
- 所有語言模型與學習都在本機，沒有網路、外部 AI、模型下載或雲端帳號。

最基本的相容範例：

| 輸入（大千） | pre-edit 結果 | 意義 |
|---|---|---|
| `su` | `su` | 注音尚未有聲調，保持原鍵 |
| `su3` | `你` | 完整音節才轉字 |
| `s3u` | `你` | 接受聲調亂序輸入 |
| `su3cl3` | `你好` | 連續中文交給語境模型組詞 |
| `su3helloji3` | `你hello我` | 中文、英文、中文可連續混輸 |
| `aceru/6aj4` | `acer螢幕` | 從英文尾端剝出最短可成立音節 |
| `(hk4g4` | `(測試` | 標點會形成邊界，不阻塞後續注音 |

## 2. 復刻範圍與優先順序

### P0：不可缺少的產品核心

1. 英文優先、完整音節才轉換的中英混輸。
2. 整段 pre-edit 與 Enter-only commit。
3. 多音節語境轉換，以及任何位置的游標編輯。
4. 任意中文字／詞的候選重選。
5. 原始按鍵復原、選字後鎖定與候選分頁。
6. 大千配置、半形標點預設、強制英文模式。
7. 不因無效音節、引擎故障或不支援快捷鍵而吞鍵。

### P1：完整使用體驗

1. 全部 11 種鍵盤配置。
2. 中文標點快捷鍵、全形標點模式與標點候選。
3. 中段插入、貼上清理、Emoji grapheme 安全編輯。
4. 個人學習、加權選字、忘記候選與 `Ctrl+Z` 選字復原。
5. 已送出中文的再轉換。
6. 狀態提示、待組注音提示、滑鼠／觸控選候選。

### P2：可攜性與維運功能

1. 個人辭典查詢、匯入、匯出、備份與重置。
2. 無 UI 的核心 API／WebAssembly 封裝。
3. Linux Fcitx5 前端、安裝輔助與套件整合。

## 3. 核心輸入狀態機

### 3.1 狀態資料

復刻時建議至少保留以下概念：

- `cells`：已定型但尚未 commit 的顯示單元。
- `liveChineseRun`：連續中文音節，保留給語境模型組詞。
- `englishBuffer`：目前英文尾段。
- `pendingSyllable`：尚未完成的原始注音鍵。
- `parkedTail`：在中段插入時，暫存在插入點右方的單元。
- `forcedEnglish`：強制英文模式，跨 composition reset 保留。
- `mode`：一般輸入、游標編輯、候選選取三種互動狀態。

每個 cell 至少需要：

```text
isChinese       是否為可重新選字的中文
text            顯示內容；通常是一個 grapheme
reading         正規化注音鍵；一聲以尾端空白作為內部標記
typedKeys       使用者實際輸入順序，用於原始鍵復原
locked          是否為使用者明確選定、之後不得被其他選字改寫
selectionGroup  同一次詞／片語選取涵蓋的 cell 群組
```

`typedKeys` 與 `reading` 不可合併：例如亂序輸入 `s3u` 的正規讀音可重新排列，但「原始鍵」候選必須還原成使用者真的輸入的 `s3u`。

### 3.2 一般按鍵判定

1. 沒有 Ctrl／Alt／Super 的可列印 ASCII 才進入一般混輸判定；未被輸入法定義的組合鍵交還宿主應用程式。
2. 大小寫注音鍵等價，`SU3` 也可轉成 `你`；若不能形成中文，必須保留原始大小寫，例如 `Acer`、`API`。
3. 一個音節最多各有一個聲母、介音、韻母與聲調。使用者輸入順序可不同，轉換前再依配置正規化。
4. 新鍵與待組音節發生類別衝突或無法成為有效音節時，整段待組鍵連同新鍵轉為英文尾段，不得遺失或提前送出。
5. 只有以下條件全部成立才轉中文：
   - 鍵序可構成合法音節；
   - 音節已完成聲調（空白代表一聲）；
   - 轉換引擎產生漢字；
   - 沒有殘留未處理的注音符號。
6. 中文連續輸入時，音節要留在同一個語境 run 中，讓模型能辨識 `我的`、`跑得快` 等同音詞。
7. 英文出現在兩段中文之間時，先凍結前一段中文與英文，再開始新的中文 run，順序不可被重設。

### 3.3 英文尾端剝音節

當英文狀態收到聲調鍵時，從尾端尋找可轉換的注音音節。這裡不能只採用「能轉字的最短 suffix」，還必須檢查切割後留下的英文前綴是否合理：

- 原則上優先取「最短、仍可實際產生漢字，且不留下疑似注音殘鍵」的尾端，盡量少吃英文內容。
- 英文前綴保持字面值，例如 `acer` + `u/6` 形成 `acer螢`。
- 大寫縮寫後也能接中文，例如 `APIji3` → `API我`。
- 單一介音鍵形成的 suffix（例如大千 `u3`）是特殊歧義：目前只有當切割後的前綴最後兩字都是小寫英文字母時才允許，避免把較長音節的聲母留在前綴。
- 例如 `acer1u32u04`：收到第一個 `3` 時，雖然 `u3` 本身可轉成「以」，但切掉 `u` 會留下 `acer1`；`1` 是大千的聲母 ㄅ，因此必須拒絕 `u3`，繼續擴張成 `1u3`（ㄅㄧˇ）。後續 `2u04` 與它進入同一中文語境，結果應為 `acer筆電`，不可變成 `acer1以電`。
- URL、email、版本號、檔名與技術字串必須偏向字面值，例如：
  - `kai@example.com`
  - `https://ari-ime.test/v1.0.0`
  - `Ari-IME-1.0.0`
  - `README.md`
- 某些配置的注音鍵本身是標點。完整而明確的「符號開頭音節」仍可轉換，但網址或檔名尾端的類似形狀不可輕易誤轉。

這個判定不能只用固定英文單字表，也不能看到可轉換的最短 suffix 就立即採用，否則品牌、縮寫、新詞或帶數字聲母的注音會被錯切；應以合法音節、實際轉換結果、切割邊界和周邊字面語境共同決定。

### 3.4 空白鍵

預設行為：

- 有未完成的合法注音 body 時，把 Space 當一聲；只有實際能產生漢字才轉換。
- 例如大千 `u` + Space → `一`。
- 無法產生漢字時，原鍵與 Space 都保留成字面內容；例如 `a ` 仍是 `a `。
- 已完成中文或一般英文之後，Space 是 pre-edit 內的字面空白，不會 commit。

選用的 `SpaceCandidateMode` 開啟後：完整中文轉換後按 Space 進入候選；未完成音節的一聲判定仍優先。此模式也不把 Space 改成 commit。

### 3.5 Commit、清除與刪除

- Enter／數字鍵盤 Enter：若 pre-edit 非空，送出整段並清空；若為空，按鍵交給應用程式。
- 除 Enter 外不得自動送出中文、英文或空白。
- 一般狀態 Backspace：依序刪除待組音節、英文尾端、中文 run 尾端、已凍結 cell。
- 一般狀態 Delete：若游標右側有 parked tail 就刪第一個；若游標已在 pre-edit 尾端則吸收按鍵但不刪應用程式文字。
- 一般狀態 Esc：有 pre-edit 時清空；沒有 pre-edit 時交給應用程式。
- composition 因焦點切換而 reset 時要清掉未送出內容，但保留使用者切換的強制英文模式。

## 4. 整段編輯與候選重選

### 4.1 兩層編輯狀態

「編輯」必須拆成兩層，避免數字鍵既是注音又誤選候選：

1. 游標模式：游標位於字元之間，沒有候選窗；所有可列印鍵（包含數字）都從游標位置開始正常組字。
2. 候選模式：焦點在一個 cell 上並顯示候選；數字 `1`–`9` 才代表選候選。

從一般輸入按 ↓、↑、←、→、Home、End 或 Ctrl+方向鍵，若 pre-edit 非空，就先凍結 live tail 再進游標編輯。空 pre-edit 時這些鍵必須交還應用程式。

### 4.2 游標模式行為

| 按鍵 | 行為 |
|---|---|
| ←／→ | 以 grapheme 為單位移動一格 |
| Home／Begin | 到 pre-edit 開頭 |
| End | 到 pre-edit 結尾 |
| Ctrl+←／Ctrl+→ | 依 libchewing 詞界或英文字詞邊界移動 |
| ↓ | 開啟游標右側 cell 的候選；在尾端時選最後一格 |
| ↑ | 中文 cell 開候選；英文 raw key 嘗試重新解讀為注音 |
| Backspace | 刪游標左側 cell |
| Delete | 刪游標右側 cell |
| 可列印鍵／Space | 在游標處開始完整的一般混輸流程 |
| Esc | 離開編輯但保留文字，之後輸入回到尾端 |
| Enter | 送出整段 |

中段組字時，插入點右方內容必須先 park；新注音照一般規則完成後再與右側內容接回。游標要停在新內容之後，而不是跳到整段尾端。

### 4.3 候選內容與順序

- 候選包含焦點所在位置可用的片語與單字；片語候選可以跨過焦點涵蓋多個 cell。
- 搜尋順序從最長片語區間一路縮到單字，再做語境排序。
- 目前顯示文字應優先，避免打開候選後第一項和 pre-edit 不一致。
- 使用者先前明確選過的 cell 要鎖定；之後改別處時不得被重新組詞覆蓋。
- 中文候選最後要有 `原始鍵 ...` 項目，選取後把該 cell 展開成實際輸入的 raw keys；一聲不額外展開 Space。
- 如果中文讀音用了 `.`、`,` 等標點形狀的實體鍵，候選順序為「全部中文候選 → 該實體鍵的標點候選 → 原始鍵」。
- 一般英文字母 cell 按 ↓ 不顯示候選；標點 cell 例外，顯示同一實體鍵家族的標點候選。
- 每頁 9 項，頁碼顯示為 `候選 x/y`。

### 4.4 候選操作

| 按鍵／操作 | 行為 |
|---|---|
| ↓／Space／Tab | 下一候選，跨頁並在末尾循環 |
| ↑／Shift+Tab | 上一候選，跨頁並在開頭循環 |
| PageDown／PageUp | 下一頁／上一頁，highlight 回到該頁第 1 項 |
| `1`–`9`／數字鍵盤 `1`–`9` | 選目前頁相對應項目 |
| Enter | 選目前 highlight，不直接 commit 整段 |
| 滑鼠／觸控 | 與數字選取共用同一路徑 |
| ←／→ | 移到相鄰 cell 並重建候選；最末 cell 再按 → 回到尾端游標 |
| Home／End | 候選焦點跳到第一／最後 cell |
| Backspace／Delete | 刪除焦點 cell，關閉候選並留在原位置 |
| Esc | 只關候選窗，回到同位置的游標模式 |
| Shift+Delete | 移除 highlight 對應的個人學習，不刪內建詞 |
| 其他可列印鍵 | 在焦點 cell 前開始中段插入 |
| 其他控制鍵 | 關候選、保留游標位置，並交還應用程式 |

前端的滑鼠 callback 可能延遲。選取 API 除頁內 index 外，還應帶建立 callback 時的候選文字；頁面或內容已變時拒絕舊 callback，避免選錯同一槽位的新候選。

### 4.5 重新解讀與選字復原

- 中文 cell 選「原始鍵」：中文展開回 `typedKeys`，回到游標模式。
- 英文 cell 按 ↑：最多向右讀取約 4 個 cell，若可組成完整注音則合併成中文並開候選。
- 重新解讀需偏向保護 URL、檔名、版本字串與欄位型技術資料。
- `Ctrl+Z` 只復原最近的候選選取，最多保留 8 份快照；任何其他文字編輯都清除這組選字 undo。
- 成功時顯示「已復原選字」。它不是通用文字 undo，也不代理應用程式的 undo。

## 5. 標點功能

### 5.1 預設與模式

- 預設所有普通標點都是半形字面值，與前後是中文或英文無關。
- `ChinesePunctuationShortcut` 用修飾鍵臨時要求中文標點，可選：`Ctrl+Shift`（預設）、`Alt+Shift`、`Ctrl`、`Alt`、停用。
- `Alt+[` 固定輸入 `「`，`Alt+]` 固定輸入 `」`；若還有 Ctrl／Shift／Super，則不攔截。
- `FullWidthPunctuation` 開啟後，不按修飾鍵也輸入全形／中文形式。
- `FullWidthPunctuationToggle` 可綁定帶修飾鍵的快捷鍵即時切換並持久化；預設未綁定，避免占用 `Ctrl+.` 等應用程式快捷鍵。
- 強制英文模式與數字鍵盤標點永遠保持半形字面值。
- 在所選鍵盤配置中屬於注音的標點鍵，優先保留給注音，不可因全形模式漏出注音符號或被誤轉成標點。

主要中文形式包括：

| 實體鍵／輸入 | 中文形式 |
|---|---|
| `,` 或 `<` | `，` |
| `.` 或 `>` | `。` |
| `/` 或 `?` | `？` |
| `'` 或 `"` 的中文標點快捷手勢 | `、` |
| `(` `)` | `（` `）` |
| `[` `]` | `「` `」` |
| `{` `}` | `『` `』` |
| `!` `:` | `！` `：` |
| `\` | `、` |
| `^` | `……` |
| `@`、`#`、`$`、`%`、`&`、`*`、`+`、`=`、直線、`~`、`_`、反引號、雙引號 | 對應全形符號 |

### 5.2 標點候選

- 對一個字面標點按 ↓，只列出同一實體鍵可產生的 base、Shift、全形、中文與配對形式，且目前形式排第一。
- 例如 `[` 家族可含 `[`, `{`, `「`, `『`, `【`, `〔`, `《`, `〈`；`]` 提供相對應的右半邊。
- 不得把視覺相似但不同實體鍵的符號混入，例如 `[` 不應出現 `!` 的候選。
- 候選系統需能辨認舊版已插入的中文標點，再反推回正確實體鍵家族。

## 6. 強制英文模式

- `Ctrl+Space` 切換；切換前凍結現有 live tail，但不 commit。
- 顯示暫時性的 `中 中文`／`英 English` 提示。
- 模式在 Enter、Esc、focus reset 後仍保留，直到再次切換。
- 強制英文時：所有可列印鍵均為字面值、標點保持半形、↑／↓ 不開中文候選；整段依然留在 pre-edit，仍由 Enter commit。

## 7. 貼上與 Unicode 編輯

宿主攔截 `Ctrl+V`、`Shift+Insert`、`Shift+KP_Insert`，取得剪貼簿文字後插入目前 pre-edit 游標。剪貼簿不可用或內容為空時，快捷鍵交還應用程式。

貼上內容視為完成的字面 cell，不進行注音轉換，並執行：

- Tab、換行、CRLF、ASCII 控制字元、DEL、NBSP、窄不斷行空白、Unicode 行／段分隔與全形空白折成單一可見空白。
- 連續分隔符折成一個空白。
- 移除 zero-width space、word joiner、BOM。
- 無效 UTF-8 或 C1 控制 cluster 不得送入 client；以安全分隔處理。
- 常見多 codepoint grapheme 必須視為一格，包括 combining mark、variation selector、膚色修飾、旗幟 regional indicators、tag sequence 與 Emoji ZWJ sequence。
- 一般 ASCII `a` + ZWJ + `b` 不可錯誤黏成一格。

游標移動、Backspace、Delete、位置計數與 UI caret 都要以 grapheme cluster 為準，不可只用 UTF-8 byte 或 Unicode code point。

## 8. 已送出文字再轉換

預設快捷鍵為 `Ctrl+Alt+R`，可改綁或清除。啟動條件全部滿足才攔截：

- 目前沒有 pre-edit，也沒有正在進行的再轉換。
- 不是強制英文模式。
- client 支援 surrounding text，且有有效、非空的選取範圍。
- 選取內容每個 grapheme 都含漢字、可反查讀音。
- 最長 32 個 grapheme。
- 不是密碼或敏感欄位。

成功時：

1. 反查每個字的讀音；已由 Ari 組過的字與重複查詢可走 bounded cache。
2. 暫時從 client 刪除原選取範圍。
3. 把原文字放入 Ari pre-edit，立即開啟既有候選編輯器。
4. Enter 送出修正結果。
5. Esc、focus reset 或中止時，把原選取文字原樣送回，避免資料遺失。

任一條件不成立時不改 client、不改 buffer，並把快捷鍵交還應用程式。第一次反查外部文字可能較慢；找不到任何一字的讀音時整次操作失敗，不做部分轉換。

## 9. 個人學習

### 9.1 學習規則

- 只有 Enter 接受整段時才學習。
- 未手動改過的中文 run：1 次弱正向學習。
- 明確選取的字／詞：在上述 1 次之外再學 3 次，約形成 4:1 權重。
- 明確選取範圍前後各最多一字，再做 1 次短語境學習。
- 明確選取或匯入的 phrase 另存 Ari 自有 preference sidecar，供備份與忘記操作；它不能取代 libchewing 的即時語境排序。
- 不可在每次完成音節時暗開候選窗掃描並硬把偏好置頂。
- `AutoLearn=false` 時仍可選字，但不可更動個人資料。
- 密碼／敏感欄位不論設定如何都禁止學習。
- 內部學習重播以最多 32 字為 chunk；長 pre-edit 仍可編輯，但跨越此界線的完整語境排序不保證。

### 9.2 忘記候選

候選模式按 `Shift+Delete`：

- 移除相同 phrase 的個人讀音與 Ari preference 記錄。
- 不刪 libchewing 內建字典中的同詞。
- 成功、沒有紀錄、不可移除都要顯示明確提示。

### 9.3 使用者資料與工具

Linux 預設資料目錄為 `$XDG_CONFIG_HOME/ari-ime`，未設定時為 `~/.config/ari-ime`；`ARI_IME_USER_DATA_DIR` 可覆寫。主要檔案包含：

- `userdict.dat`／`chewing.dat`：不同 libchewing 版本的學習資料。
- `chewing-deleted.dat`：刪除紀錄。
- `preferences.tsv`：Ari 明確偏好 sidecar。
- `uhash.dat`：某些舊版／WASM 使用的學習檔。

`ari-ime-dict` 現有命令：

```text
info
list
export [FILE|-]
import [--dry-run] FILE|-
backup
candidates KEYS
```

可攜文字格式：

```text
# Ari IME user dictionary v1
# One entry per line: phrase<TAB>canonical Bopomofo reading
你好<TAB>ㄋㄧˇㄏㄠˇ
```

匯入必須先驗完整檔案、接受首行 UTF-8 BOM、拒絕非正規注音讀音、去除重複、合併而非覆蓋，並在修改前建立時間戳備份。匯出先寫暫存檔再替換，失敗不可截斷既有檔案。文字格式只保證 phrase／reading 可攜，不保證跨 libchewing 版本保留精確詞頻與刪除狀態；原始備份用於同引擎復原。

## 10. 鍵盤配置

| 顯示名稱 | 內部名稱 | `你` | `你好` |
|---|---|---|---|
| 大千 | `Default` | `su3` | `su3cl3` |
| 倚天 | `Eten` | `ne3` | `ne3hz3` |
| 許氏 | `Hsu` | `nef` | `nefhwf` |
| IBM | `Ibm` | `7a,` | `7a,-;,` |
| 精業 | `GinYieh` | `d-a` | `d-avla` |
| Dvorak | `Dvorak` | `og3` | `og3jn3` |
| Carpalx | `Carpalx` | `su3` | `su3cl3` |
| Colemak-DH ANSI | `ColemakDhAnsi` | `rl3` | `rl3di3` |
| Colemak-DH Ortholinear | `ColemakDhOrth` | `rl3` | `rl3ci3` |
| Workman | `Workman` | `sf3` | `sf3mo3` |
| Colemak | `Colemak` | `rl3` | `rl3ci3` |

配置層必須同時提供「鍵屬於哪個注音 slot」與「底層轉換引擎的 keyboard type」，避免 parser 與字典引擎對同一鍵有不同解讀。切換配置時：

- 清空目前未送出的 pre-edit。
- 清除以舊配置 raw keys 建立的反查 cache。
- 顯示暫時性的配置提示。
- 配置不可用時退回大千並提示。

拼音配置刻意不支援，因為這套 parser 假設一鍵對應一個注音符號。

## 11. 數字鍵盤

- NumLock 開啟的 `KP_0`–`KP_9` 與 `KP_Decimal/Divide/Multiply/Subtract/Add/Equal` 一律當字面字元，不可變成注音或聲調。
- NumLock 關閉時，KP Home／方向鍵／PageUp／PageDown／End／Begin／Delete 等正規化為主鍵盤導航鍵。
- KP Enter 等同 Enter。
- 候選模式下 KP `1`–`9` 可選候選。

## 12. UI 行為與設定

### 12.1 Pre-edit 與輔助列

- 整段 pre-edit 顯示底線並回報正確 caret byte offset。
- 候選模式要可靠標示單一焦點字。因部分 client 忽略分段 style，Linux 前端另在 Fcitx 輔助列顯示前後最多約 10 格的截短預覽與焦點。
- 游標模式顯示 `游標 n/總數`；候選模式顯示 `選字 n/總數`。
- 候選超過一頁顯示 `候選 x/y`。
- 可選狀態列格式：`中 · 大千 · 半形標點` 或 `英 · … · 全形標點`。
- 可選待組注音提示：只在未完成音節期間顯示不含聲調的注音符號；轉字、變英文或開候選後消失。
- 一般輸入完成中文時不自動開候選面板；目前 pre-edit 結果就是即時推薦。

### 12.2 設定清單

| 設定 | 預設 | 功能 |
|---|---|---|
| `KeyboardLayout` | `Default` | 11 種注音配置 |
| `FullWidthPunctuation` | `false` | 無修飾鍵也用全形／中文標點 |
| `ChinesePunctuationShortcut` | `ControlShift` | 臨時中文標點手勢 |
| `SpaceCandidateMode` | `false` | 完整中文後 Space 開候選 |
| `ReconversionKey` | `Ctrl+Alt+R` | 已送出中文再轉換 |
| `AutoLearn` | `true` | 本機個人學習 |
| `ShowStatusLine` | `false` | composition 狀態列 |
| `ShowPendingZhuyin` | `false` | 顯示待組注音符號 |
| `FullWidthPunctuationToggle` | 空 | 即時切換全形標點的快捷鍵 |

## 13. 平台介面分層

復刻到非 Linux 專案時，不應把 Fcitx5 事件直接寫進核心。建議分三層：

```text
平台前端
  ├─ 鍵盤事件／修飾鍵正規化
  ├─ pre-edit、caret、候選 UI
  ├─ commit、clipboard、surrounding text
  └─ 敏感欄位能力判定
          ↓
Ari 狀態機
  ├─ 中英混輸與音節判定
  ├─ cells／中段編輯／候選整合
  ├─ 標點、貼上、undo、reconversion
  └─ 學習時機與權重
          ↓
注音轉換後端
  ├─ 音節轉字與候選
  ├─ 組詞／語境排序／詞界
  ├─ 讀音反查
  └─ 個人辭典持久化
```

核心對前端至少回傳：

```text
handled, hasCommit, commitText, updateUI
notifyMode, notification, engineReady
preedit, caretChar
candidates, candidatePage, candidatePageCount, highlight
selectionChar, editing, picking
```

核心至少提供：處理按鍵、選取候選、貼上、再轉換、commit、reset、切換學習、切換配置、切換標點設定、匯出／匯入學習狀態、釋放資源。專案內 `@ari-ime/wasm` 已採用這種 headless API，可作為跨平台行為介面的參考；clipboard、候選繪製與持久化仍由宿主負責。

## 14. 失敗與安全行為

- 初始化 libchewing 失敗時，先嘗試只讀 context；仍失敗則降級為英文 passthrough，並只提示一次「注音引擎載入失敗，暫以英文輸入」。不可吞鍵或讓使用者無法輸入。
- 候選排序由 libchewing 版本與本機學習資料決定；測試不應硬綁所有候選的絕對順序，只驗 Ari 自己控制的順序與不變條件。
- 密碼／敏感欄位不得學習、不得讀 surrounding selection 做再轉換。
- 已送出文字再轉換中若 Esc 或 focus reset，必須復原原文字。
- 長字串仍可編輯；只有最近至多 32 個中文字保證處於轉換引擎有效語境窗。
- 所有未認得、未處理或有平台快捷鍵修飾的事件都應 pass through。

## 15. 驗收案例

### 核心混輸

- [ ] `su` 顯示 `su`；`su3` 顯示 `你`；`s3u` 也顯示 `你`。
- [ ] `su3helloji3` 顯示 `你hello我`，Enter 一次送出完整結果。
- [ ] `aceru/6aj4` 顯示 `acer螢幕`。
- [ ] `acer1u32u04` 顯示 `acer筆電`；第一音節使用完整的 `1u3`，不可先吃掉較短的 `u3` 而留下 `1`。
- [ ] Email、URL、版本、檔名與 acronym 不被錯誤轉換。
- [ ] Space 只有在實際有一聲漢字結果時轉字，其他情況插入字面空白。
- [ ] 無 pre-edit 的 Enter、Esc、導航鍵不被攔截。

### 編輯與候選

- [ ] 可在 `你好` 之前、中間、之後插入新的注音或英文。
- [ ] 可從任意中文字開候選，選片語後其他已選字不被改回。
- [ ] 候選每頁 9 項，鍵盤、滑鼠、Tab、PageUp／Down 的 index 一致。
- [ ] 延遲滑鼠 callback 不會套到已變更的頁面。
- [ ] 原始鍵候選保留亂序輸入順序。
- [ ] `Ctrl+Z` 能復原連續選字，但普通編輯後不再攔截應用程式 undo。
- [ ] `Shift+Delete` 只忘記個人紀錄。

### 標點與配置

- [ ] 預設中文後的 `?` 仍是半形 `?`。
- [ ] 預設中文標點快捷鍵能輸入 `，。？、`。
- [ ] `Alt+[`／`Alt+]` 輸入 `「」`，`Ctrl+Alt+[` 不攔截。
- [ ] 全形模式不破壞各配置中長得像標點的注音鍵。
- [ ] 標點候選只出現同一實體鍵家族。
- [ ] 11 種配置的 `你好` smoke test 通過；切配置會清空 pre-edit。

### Unicode、學習與整合

- [ ] 貼上會清理控制／零寬字元、摺疊分隔符，且能在游標中間繼續組字。
- [ ] Emoji、旗幟、variation selector 與 ZWJ sequence 用一次 Backspace 刪除。
- [ ] 敏感欄位不學習、不做再轉換。
- [ ] 1 次預設學習與約 4:1 明確選字加權可被自動測試觀察。
- [ ] 辭典 dry-run 完全不修改資料；匯入前備份且可重複執行。
- [ ] 引擎缺失時所有文字仍能以英文輸入。

## 16. 明確不屬於目前功能

- 拼音輸入配置。
- 雲端同步、網路 AI、遠端模型或候選服務。
- 一完成音節就自動彈出候選窗。
- Space commit 整段（目前只有 Enter commit；Space-to-candidate 也只是選用模式）。
- 跨 libchewing 版本逐 byte 保留詞頻資料。
- 在不支援 surrounding text 的 client 強制修改已送出文字。

## 17. 復刻注意事項

1. 最難復刻的是中英判定與 cell／tail 編輯模型，不是鍵盤映射。應先讓 P0 狀態機測試通過，再接平台 UI。
2. 不要把 pre-edit 顯示字串當唯一資料來源；沒有 reading、typed keys、lock 與 selection group，就無法正確重選、復原與學習。
3. 候選 UI 的頁內 index、全域 index 和延遲 click 必須明確分開。
4. Grapheme segmentation 應優先使用目標平台成熟的 Unicode API；原專案為減少 Linux addon 依賴才自行實作常用子集。
5. 若不用 libchewing，需要替代後端同時提供音節轉字、片語候選、語境排序、詞界、讀音反查和個人學習，否則只能達到外觀相似，無法達到目前行為。
6. 原專案使用 GPL-3.0-or-later。若另一個專案直接複製或改寫受著作權保護的原始碼，需另行確認授權相容性；只依功能規格重新實作也應保留清楚的來源與決策紀錄。
