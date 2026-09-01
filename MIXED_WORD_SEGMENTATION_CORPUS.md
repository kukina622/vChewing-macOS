# 中英混輸詞彙切分測試集（大千）

> 用途：交給新的輸入法實作，測試「英文直接接注音」時是否從正確位置切出完整中文字詞。
>
> 這是期望行為 corpus，不代表 Ari IME 2.6.2 的每一筆目前都會通過；其中不少案例正是用來重現現有切分或選詞問題。

## 使用規則

- 鍵盤配置固定為大千（`Default`）。
- `␠` 表示按一次 Space，作為前一個音節的一聲，不是測試資料中的六個 ASCII 字元。
- 預期結果中的 ` | ` 只標示英／中文詞界，不是實際輸出的空白。
- 例如 `acer1u32u04 -> acer | 筆電` 的實際 pre-edit 期望是 `acer筆電`。
- 每一題都從空 buffer 開始，關閉個人學習，輸入完後直接檢查 pre-edit；不需要按 Enter。
- 比對時除了檢查最終漢字，也必須檢查第一個中文字使用的完整 reading，避免碰巧選到同字卻切錯 raw keys。

自動測試可把每行右側的 ` | ` 移除後，作為完整 pre-edit 的期望值。

## A. 電腦與硬體詞彙

```text
acer1u32u04 -> acer | 筆電
acer2u04sl3 -> acer | 電腦
aceru/6aj4 -> acer | 螢幕
acerru04q06 -> acer | 鍵盤
acercj86gj3 -> acer | 滑鼠
acerqu/6103 -> acer | 平板
acer-3ru␠ -> acer | 耳機
acerg.3ru␠ -> acer | 手機
acervu;␠ru␠ -> acer | 相機
acertj/␠2u04fu4 -> acer | 充電器
acertj/␠2u04vu04 -> acer | 充電線
acer2u04t6 -> acer | 電池
acervu03g4fu4 -> acer | 顯示器
acervu03g4d83 -> acer | 顯示卡
acertj3xu3fu4 -> acer | 處理器
acerru4u4wu3 -> acer | 記憶體
aceru/42u,6 -> acer | 硬碟
acer2u04m06 -> acer | 電源
acer2u04xu;4 -> acer | 電量
acerjp␠2j4 -> acer | 溫度
acervul4s/6 -> acer | 效能
acerj;3xj4d83 -> acer | 網路卡
acerj6vu04j;3xj4 -> acer | 無線網路
acerx06u86-3ru␠ -> acer | 藍牙耳機
acer5j03ru,␠fu4 -> acer | 轉接器
acerxu06ru,␠vu04 -> acer | 連接線
acerru,3vu␠2j4 -> acer | 解析度
aceryji4u,4vu4wj/3 -> acer | 作業系統
acervm␠su3ru␠ -> acer | 虛擬機
acer5j;␠54 -> acer | 裝置
```

## B. 軟體與開發詞彙

```text
acert/6g4 -> acer | 程式
acerru,4au04 -> acer | 介面
acerj;3504 -> acer | 網站
acervu4wj/3 -> acer | 系統
acergk42u/4 -> acer | 設定
acer1031p3 -> acer | 版本
acerhk4g4 -> acer | 測試
acer04xu4 -> acer | 案例
acerjp4wu6 -> acer | 問題
acerhji4j4 -> acer | 錯誤
acervmp4vu␠ -> acer | 訊息
acerru/3el4 -> acer | 警告
acert/6ej/␠ -> acer | 成功
acerg␠194 -> acer | 失敗
acerg;4tj06 -> acer | 上傳
acervu84y94 -> acer | 下載
acer2;304 -> acer | 檔案
acery␠xul4ru86 -> acer | 資料夾
acerwj6qu04 -> acer | 圖片
aceru/3qu04 -> acer | 影片
acerup␠vmp4 -> acer | 音訊
acerup␠m,4 -> acer | 音樂
acerek6g4 -> acer | 格式
acerjp6ru04 -> acer | 文件
acerxu.6x03fu4 -> acer | 瀏覽器
acerg3m/4xm4 -> acer | 使用率
acerxu06ru,6 -> acer | 連結
acer1ul␠fu0␠ -> acer | 標籤
acervm0320␠ -> acer | 選單
acerg.3u,4 -> acer | 首頁
acern.␠vmp6 -> acer | 搜尋
acercj84au04 -> acer | 畫面
aceru/4vu;4 -> acer | 映像
acerck6vup␠ -> acer | 核心
aceru/4m/4 -> acer | 應用
acerwl4ru04 -> acer | 套件
acervu/61u,6 -> acer | 型別
acergk4ru4 -> acer | 設計
acergp3t86 -> acer | 審查
acerfu/3fu.6 -> acer | 請求
acerwu6rul␠ -> acer | 提交
acerzp␠5␠ -> acer | 分支
acer1o4zp4 -> acer | 備份
acere/␠vup␠ -> acer | 更新
acerwj/␠5␠ -> acer | 通知
acerej/␠s/6 -> acer | 功能
acerfm06vu04 -> acer | 權限
acery␠xul4dj4 -> acer | 資料庫
```

## C. 網路、帳號與一般 UI 詞彙

```text
acerxu06vu04 -> acer | 連線
acerau4a83 -> acer | 密碼
acereji4fu␠ -> acer | 過期
acerjo453 -> acer | 位址
acerqu/65/4 -> acer | 憑證
acerrup␠ul4 -> acer | 金鑰
acerxu06ru,␠1j4 -> acer | 連接埠
acer5;4cl4 -> acer | 帳號
acerek4bp6y␠xul4 -> acer | 個人資料
acerxul6wu0␠ -> acer | 聊天
acercjo4u4 -> acer | 會議
acervu/6g4xu4 -> acer | 行事曆
acerfu/␠20␠ -> acer | 清單
acer2/␠bj4 -> acer | 登入
acer2/␠tj␠ -> acer | 登出
acercjo4m06 -> acer | 會員
acern4zj6fu4 -> acer | 伺服器
acerzj6j4 -> acer | 服務
acerm/4cj4 -> acer | 用戶
acerej03xu3m06 -> acer | 管理員
acery␠xul4wj/61j4 -> acer | 資料同步
acerj;3m4 -> acer | 網域
acer2j0␠2u03 -> acer | 端點
acer294xu3 -> acer | 代理
acerz;6cji3fu;6 -> acer | 防火牆
acer0␠fm06vu/4 -> acer | 安全性
aceru045/4 -> acer | 驗證
acerg.4fm06 -> acer | 授權
```

## D. 不同英文前綴的詞界壓力測試

這組用相同中文字詞搭配不同型態的英文前綴，避免修正只對 `acer` 有效。

```text
ASUS1u32u04 -> ASUS | 筆電
ThinkPad1u32u04 -> ThinkPad | 筆電
MacBook1u32u04 -> MacBook | 筆電
Lenovo2u04sl3 -> Lenovo | 電腦
Dell2u04sl3 -> Dell | 電腦
Logitechcj86gj3 -> Logitech | 滑鼠
USBru04q06 -> USB | 鍵盤
iPhoneg.3ru␠ -> iPhone | 手機
iPadqu/6103 -> iPad | 平板
NVIDIAvu03g4d83 -> NVIDIA | 顯示卡
Inteltj3xu3fu4 -> Intel | 處理器
AMDvul4s/6 -> AMD | 效能
WiFij;3xj4 -> WiFi | 網路
Bluetooth-3ru␠ -> Bluetooth | 耳機
GitHub1o4zp4 -> GitHub | 備份
Dockeru/4vu;4 -> Docker | 映像
Reactru,4au04 -> React | 介面
Vuewl4ru04 -> Vue | 套件
VSCodegk4ru4 -> VSCode | 設計
Linuxck6vup␠ -> Linux | 核心
Windowse/␠vup␠ -> Windows | 更新
Androidu/4m/4 -> Android | 應用
Chromexu.6x03fu4 -> Chrome | 瀏覽器
APIjp6ru04 -> API | 文件
HTTPfu/3fu.6 -> HTTP | 請求
JSONek6g4 -> JSON | 格式
HTML1ul␠fu0␠ -> HTML | 標籤
CSSu;4g4 -> CSS | 樣式
Pythonwl4ru04 -> Python | 套件
npmwl4ru04 -> npm | 套件
win112u04sl3 -> win11 | 電腦
x86tj3xu3fu4 -> x86 | 處理器
user1235;4cl4 -> user123 | 帳號
api_v2ru,4au04 -> api_v2 | 介面
ari-ime1031p3 -> ari-ime | 版本
v2.6.2gk42u/4 -> v2.6.2 | 設定
```

注意：此處的大小寫英文字母必須原樣保留。測試 harness 不可為了注音判定先把整段輸入轉成小寫。

## E. 第一個中文字是一聲的必要案例

目前最容易漏掉的是：英文狀態下按 Space 可能直接被當作字面空白，而沒有先嘗試用它完成第一個中文音節。以下 `␠` 都是聲調一聲，預期結果中不應多出空白。

```text
acerg␠194 -> acer | 失敗
acertj/␠2u04fu4 -> acer | 充電器
acervu;␠ru␠ -> acer | 相機
acerup␠vmp4 -> acer | 音訊
acerup␠m,4 -> acer | 音樂
acere/␠vup␠ -> acer | 更新
acerwj/␠5␠ -> acer | 通知
acerej/␠s/6 -> acer | 功能
acery␠xul4dj4 -> acer | 資料庫
acerfu/␠20␠ -> acer | 清單
acer2/␠bj4 -> acer | 登入
acer2/␠tj␠ -> acer | 登出
acer0␠fm06vu/4 -> acer | 安全性
acerjp␠2j4 -> acer | 溫度
acerrup␠ul4 -> acer | 金鑰
acer1ul␠fu0␠ -> acer | 標籤
acerck6vup␠ -> acer | 核心
acervm␠su3ru␠ -> acer | 虛擬機
acerg.3ru␠ -> acer | 手機
acer-3ru␠ -> acer | 耳機
```

## F. 最短 suffix 不得搶走完整音節

這組除了比對最終字串，也要檢查第一個中文 cell 的 raw reading，因為錯誤實作可能先吃掉 `u3`、`u0`、`j3`、`u/` 等較短音節。

```text
acer1u32u04 -> acer | 筆電
acer2u04sl3 -> acer | 電腦
acerru04q06 -> acer | 鍵盤
acercj86gj3 -> acer | 滑鼠
acervu03g4fu4 -> acer | 顯示器
acertj3xu3fu4 -> acer | 處理器
acerru4u4wu3 -> acer | 記憶體
acerxu06vu04 -> acer | 連線
acerau4a83 -> acer | 密碼
acerru/3el4 -> acer | 警告
acerfu/3fu.6 -> acer | 請求
acerwu6rul␠ -> acer | 提交
acerfm06vu04 -> acer | 權限
acerqu/65/4 -> acer | 憑證
acerxu06ru,␠1j4 -> acer | 連接埠
acerxul6wu0␠ -> acer | 聊天
acercjo4u4 -> acer | 會議
acervm0320␠ -> acer | 選單
acer1031p3 -> acer | 版本
acer2;304 -> acer | 檔案
```

最低要求：

- `acer1u32u04` 的第一個中文 reading 必須是 `1u3`，不能是 `u3`。
- `acer2u04sl3` 的第一個中文 reading 必須是 `2u04`，不能是 `u04`、`u0` 或其他尾端子字串。
- `acerru04q06` 的第一個中文 reading 必須是 `ru04`，不能留下字面 `r`。
- `acercj86gj3` 的第一個中文 reading 必須是 `cj86`，不能留下字面 `c`。
- 不含英文字母的 `103`（版）與 `2;3`（檔）仍然必須能從英文尾端切出，不可因「body 必須含英文字母」之類的保護規則而整段保持英文。

## G. 不應切成中文的反例

修正詞界時不可讓技術字串開始過度轉換。以下輸入應保持完全相同：

```text
kai@example.com -> kai@example.com
https://ari-ime.test/v1.0.0 -> https://ari-ime.test/v1.0.0
https://ari-ime.test/.3-3 -> https://ari-ime.test/.3-3
README.md -> README.md
README.3-3 -> README.3-3
Ari-IME-2.6.2 -> Ari-IME-2.6.2
v1.0.0.3-3 -> v1.0.0.3-3
api/v2/users -> api/v2/users
localhost:8080 -> localhost:8080
127.0.0.1:3000 -> 127.0.0.1:3000
user_id=123 -> user_id=123
status=ok -> status=ok
file-name.tar.gz -> file-name.tar.gz
hello_world -> hello_world
foo/bar?x=1 -> foo/bar?x=1
API -> API
HTTP -> HTTP
acer -> acer
```

## H. 建議的通過標準

1. 先通過 F 節 20 題；這是切分演算法的最小回歸集合。
2. 再通過 A～C 節，確認常用詞能得到指定詞組，而不是只有讀音正確、漢字仍錯。
3. E 節必須確認 `␠` 被消耗為一聲，輸出中沒有多餘空白。
4. D 節確認結果不依賴某一個英文品牌或最後兩個英文字母。
5. G 節必須全部保持字面值；任何一題被轉成中文都視為過度切分。
6. 若底層詞庫沒有「筆電、程式、介面」等目標詞，應把它記為候選／詞庫失敗，不可誤報為 reading 切分成功。

建議每題至少記錄：

```text
input
actualPreedit
expectedPreedit
englishPrefix
firstChineseReading
allChineseReadings
pass
failureType = boundary | reading | candidate | tone1 | literal-regression
```
