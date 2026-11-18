# 會計師題庫（歷屆試題庫）

純靜態網頁題庫，用 GitHub Pages 發佈，不需要伺服器或資料庫。

## 內容
- 歷屆原始題目 85 題：審計學 25、中級會計學 25、中級會計學（高普考）19、會計學概要 16，每題保留年度、考試與來源 PDF 頁碼。
- 法規題庫（自訂，不分年度）：可自行新增題目，填法條即可，答錯時自動顯示法條原文。
- 內建 23 部全國法規資料庫法規（含公司法、證券交易法、稅法等）。

## 檔案
| 檔案 | 說明 |
|---|---|
| `index.html` | 整個題庫網頁（題目、法規、程式都在這一個檔案） |
| `data/questions.json` | 85 題的原始資料備份，可匯入 Supabase |
| `.github/workflows/pages.yml` | push 到 main 後自動發佈到 GitHub Pages |

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
3. 到 repo 的 Settings → Pages，Source 選 **GitHub Actions**。
4. 到 Actions 分頁等部署完成，網址為 `https://<你的帳號>.github.io/cpa-question-bank/`。

## 更新題目
改 `index.html`（或換成新版）後 `git commit` 再 `git push`，約 1 分鐘內網站會更新。

## 注意
- 自訂題只存在使用者自己的瀏覽器（localStorage），換電腦需用「管理自訂題」匯出 JSON 備份再匯入。
- 公開 repo 與公開網址任何人都能看到全部題目與解答。答案來源：會計學概要為考選部公告，其餘為高點詳解，解析為自行撰寫。若有版權疑慮，請用 Private repo；Private repo 使用 Pages 需要 GitHub Pro／Team 付費方案。
- 法規資料來源：全國法規資料庫，依政府資料開放授權條款第 1 版。
