# 會計師題庫（歷屆試題庫）

用 GitHub Pages 發佈的靜態網頁題庫，自訂題可選擇存到 Supabase 雲端帳號，換電腦登入就看得到。

## 內容
- 歷屆原始題目 85 題：審計學 25、中級會計學 25、中級會計學（高普考）19、會計學概要 16，每題保留年度、考試與來源 PDF 頁碼。
- 內建題 2,615 題，不分年度：法規題 2,451 題（公司法 500、證券交易法 973、稅務法規 700、商業會計法 100、會計師法與職業道德 58、其他公司與金融法規 120；其中 47 題人工編寫，其餘由條文自動編製）＋審計準則題 164 題（審計準則 200、210、240、315、330、450、500、505、540、550、570、700 號，依會計研究發展基金會公布內容改寫，每題標明條號）。公司法 500 題、稅務法規 700 題（所得稅法、營業稅法、土地稅法、稅捐稽徵法、納稅者權利保護法、遺產及贈與稅法、所得基本稅額條例、營利事業所得稅查核準則，含施行細則），依命題大綱範圍，盡量每個可出題的條文至少一題；稅務法規為涵蓋全部條文，題數超過 500。每題都標明對應條文，答錯時顯示條文原文。
- 法規題庫也可自行新增題目，填法條即可。
- 內建 26 部法規（新增營業稅法、遺產及贈與稅法、所得基本稅額條例之施行細則）（公司法、證券交易法、稅法等）。

## 檔案
| 檔案 | 說明 |
|---|---|
| `index.html` | 整個題庫網頁 |
| `config.js` | Supabase 網址與公開金鑰（可公開；**不可**放 service_role／secret 金鑰） |
| `data/questions.json` | 85 題歷屆題原始資料備份 |
| `data/law_questions.json` | 2,615 題內建題（法規＋審計準則）（與網頁「匯入」相同格式，可匯入雲端帳號） |
| `supabase/migrations/` | 資料庫 migration（已套用到 Supabase 專案 `cpa-smartbank`） |
| `.github/workflows/pages.yml` | push 到 main 後自動發佈 |

## 發佈步驟（Windows PowerShell）
1. 到 https://github.com/new 建立新 repository，例如 `cpa-question-bank`。
2. 在本資料夾執行：
   ```
   git init -b main
   git add .
   git commit -m "init question bank"
   git remote add origin https://github.com/<你的帳號>/cpa-question-bank.git
   git push -u origin main
   ```
3. Settings → Pages，Source 選 **GitHub Actions**。
4. 網址：`https://<你的帳號>.github.io/cpa-question-bank/`

## 雲端同步（Supabase）設定
1. **建立帳號**：Supabase 後台 → Authentication → Users → Add user，輸入 Email 與密碼（勾選 Auto Confirm）。
2. **設為管理員**（在 SQL Editor 執行，換成你的 Email）：
   ```sql
   update public.profiles set role = 'admin'
   where id = (select id from auth.users where email = 'you@example.com');
   ```
   新帳號預設是「學生」，只能練習已發佈的題目；「審核者」可新增自己的草稿；「管理員」可新增科目、發佈、修改全部。
3. **匯入法規資料**（雲端自訂題要連結法條時，資料庫必須有該條文）：在 Next.js 專案資料夾 `.env.local` 填入 `SUPABASE_SERVICE_ROLE_KEY`（Supabase → Project Settings → API，只能放在自己的電腦），然後執行 `npm run laws:fetch` 與 `npm run laws:import`。
4. **建議關閉公開註冊**：Authentication → Sign In / Providers → 關閉 Allow new users to sign up。網頁沒有註冊功能，帳號由你建立。
5. 開網頁 → 首頁「登入」。登入後自訂題存在雲端；若本機原本有自訂題，會出現「上傳本機 N 題到雲端」。

## 行為說明
- 雲端新增的自訂題一律是**草稿**；要讓學生看到，需由管理員在 Next.js 後台 `/admin/bank` 發佈。
- 作答紀錄只存在各瀏覽器，不會同步。
- 沒設定或無法連線時，網頁自動退回「只存本機」模式。
- 公開 repo 與公開網址任何人都能看到全部題目與解答。答案來源：會計學概要為考選部公告，其餘為高點詳解，解析為自行撰寫。若有版權疑慮請用 Private repo（Private repo 使用 Pages 需要 GitHub Pro／Team）。
- 法規資料來源：全國法規資料庫，依政府資料開放授權條款第 1 版。

## 把內建題存入雲端（選用，管理員）
用管理員帳號登入 → 「管理自訂題」→ 按「把內建題 2615 題存入雲端」。每批 100 題由資料庫函式 `import_builtin_questions` 寫入 `bank_questions`（草稿、origin = custom），可重複按，已存在的會略過，中途失敗可續傳。這些雲端副本供後台審核／發佈使用，網頁不會把它們和內建題重複顯示。
