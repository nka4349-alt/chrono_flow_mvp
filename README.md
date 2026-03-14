# ChronoFlow patch v3 (復旧 + 次タスクの土台)

このパッチは「壊れた状態」から **グループ編集ボタン / グループのイベント取得 / メンバー表示 / 個人カレンダーのフレンド表示 / イベントチャットの土台** をまとめて復旧します。

## 直るもの

- ✅ グループツリーに **折りたたみ(▶/▼)** と **子グループ追加(+) / 編集(✎)** ボタンが戻る
- ✅ `/api/groups/:id/events` が復活し、グループカレンダーが 404/500 で落ちない
- ✅ `/api/groups/:id/members` が復活し、右サイドバーにメンバーが表示される
- ✅ 個人カレンダー（個人モード）では右サイドバーにフレンド一覧を表示（`/api/friends`）
- ✅ チャットが **グループ / イベント** で切り替わる（イベントをクリックするとイベントチャットへ）

## 適用方法

プロジェクト直下で以下を実行してください。

```bash
cd ~/projects/chrono_flow_mvp

# 念のためバックアップ（任意）
cp config/routes.rb config/routes.rb.bak

# パッチを上書き展開
unzip -o /mnt/c/Users/*/Downloads/chronoflow_patch_v3.zip -d .

# サーバ再起動
bin/rails restart
# もしくは起動中のrailsを止めてから bin/dev または bin/rails s
```

## 動作確認チェックリスト

1. 画面左のグループツリーに ▶/▼ がある（子があるグループだけ）
2. 各グループ行の右側に `+` と `✎` が出る（ホバー時）
3. グループを選ぶと右サイドバーにメンバーが出る
4. 個人ボタン（左上の「個人」）を押すと右サイドバーがフレンド一覧に切り替わる
5. グループを選んでイベント作成 → グループカレンダーに出る（個人には自動では出ない）
6. イベントをクリックするとチャットが Event#xxx に切り替わる

## もしまだ 404/500 が出る場合

- `bin/rails routes | grep api/groups` を実行し、以下が存在するか確認:
  - `GET /api/groups/:id/events`
  - `GET /api/groups/:id/members`
  - `GET /api/groups/:group_id/chat_messages`
- Railsログに `ActionNotFound` が出る場合は controller のファイル名/パスが違う可能性があります。
  - `app/controllers/api/groups_controller.rb` が存在するか確認してください。
