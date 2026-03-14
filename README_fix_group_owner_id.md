# ChronoFlow: グループ作成 500（groups.owner_id NOT NULL）修正

## 症状
- グループ作成時に `HTTP 500`
- サーバ側に `SQLite3::ConstraintException: NOT NULL constraint failed: groups.owner_id`

## 原因
`groups.owner_id` が DB で NOT NULL なのに、`POST /api/groups` の作成処理で `owner_id` がセットされていないため。

## このパッチがやること
- `app/controllers/api/groups_controller.rb` の `create` に以下を追加します。
  - `owner_id ||= current_user.id`
  - 作成者を `GroupMember(role: admin)` として加入
  - （存在すれば）`ChatRoom` をグループ用に作成

## 適用
```bash
cd ~/projects/chrono_flow_mvp
bash /path/to/apply_cf_fix_group_owner_id.sh .
```

※ スクリプトは自動で `.bak_YYYYmmdd_HHMMSS` バックアップを作ります。

## 適用後
- ブラウザでグループ作成（+追加/モーダル保存）を再実行
- まだ 500 の場合は `log/development.log` の create スタックトレースを貼ってください
