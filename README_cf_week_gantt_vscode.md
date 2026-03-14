# ChronoFlow UI Patch (Fixed)

このパッチは以下を自動で行います（無料の dayGridWeek 前提）：

- Week(dayGridWeek)で「同日イベント」を start/end に応じてセル内で横ズレ/長さ調整（疑似ガント）
- Month/Week(dayGrid) のイベントバーを細くする（Day(timeGrid)は変更しない）
- 左サイドバーのグループツリー(#cf-group-tree)をVSCode風に（折りたたみ▶/▼）

## 使い方

```bash
bash apply_cf_week_gantt_and_vscode_sidebar.sh .
# Rails再起動
bin/rails s
```

ブラウザは必ず `Ctrl + Shift + R`（強制リロード）をしてください。

## 確認コマンド

```bash
grep -n "CF_WEEK_GANTT_EVENT_DID_MOUNT" -n app/javascript/application.js
grep -n "CF_THIN_DAYGRID_BARS" -n app/assets/stylesheets/application.css
```
