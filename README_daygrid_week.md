# ChronoFlow: Week view を dayGridWeek（無料）でガントっぽくする

このパッチは FullCalendar の week 表示を **timeGridWeek → dayGridWeek** に切り替えます。

## 使い方（WSL）

```bash
cd /home/kan/projects/chrono_flow_mvp

# パッチ実行（自動でバックアップ作成します）
/tmp/apply_daygrid_week_patch.sh .

# サーバ再起動
# Ctrl+C で止めてから
bin/rails s
```

> `timeGridWeek` が見つからない場合は何も変更しません。

## 変更内容
- `timeGridWeek` を `dayGridWeek` に置換

## 戻したい場合
バックアップファイル（`application.js.bak_YYYYMMDD_HHMMSS`）を元に戻してください。
