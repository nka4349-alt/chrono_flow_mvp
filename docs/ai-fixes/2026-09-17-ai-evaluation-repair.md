# ChronoFlow AI候補 修正結果（9/14・9/17評価対応）

## 対象・版・状態

- 対象: ChronoFlow個人AI秘書の候補生成と表示。
- 公開評価URL: https://chrono-flow-mvp.onrender.com 。今回の実装修正はローカルのみ。公開版の改善は未確認。
- 作業場所: `/Users/user/.codex/ai-fix-worktrees/chronoflow-20260914-222701`
- ブランチ: `codex/chronoflow-ai-eval-fix-20260914-222701`
- 初回の再現基準: `b807a9580fae11dbdb96b589809cda79b108de62`
- 現在の統合基準: `origin/main` / `4acf9abe4ee0fc2633631c2e4ef86ecb1b92bb94`
- 最新main上の実装修正コミット: `ff09e44f50b3e811db84691a596a06322c84167b`（rebase前: `d5108301a33872db11066640d275e83ed86d13f9`）
- 作業前の変更を保持して同じworktreeで再開。元の作業場所、Gemfile.lock、既存DBは変更していない。追加の修正タスク・worktree、push、PR、自動マージ、デプロイは作成・実施していない。
- 使用スキル: `/Users/user/.codex/skills/chrono-ai-fix/SKILL.md`（実装修正モード）。作業場所と祖先に追加のAGENTS.mdはなかった。

## 最新mainへの統合確認

「コミットまで」の追加依頼を受け、同じ作業ブランチの修正・報告2コミットを、取得して確認した最新main `4acf9abe4ee0fc2633631c2e4ef86ecb1b92bb94` 上へrebaseした。競合なし。`git range-diff`で両パッチが同一であることを確認した。

- 実装修正: `d510830` → `ff09e44`。既存の修正10ファイルの内容は同一。
- 従来の報告: `0d36bf6` → `23f6224`。この統合確認を別のローカルコミットで追記。
- 最新mainのSpecialist Accept-Encoding変更3ファイルはmainとの差分ゼロ。JSON媒体型、認証・サイズ・スキーマの検証を保持。
- 統合後の全Ruby: **483 tests / 22,873 assertions / 0 failures / 0 errors / 0 skips**。ログ: `tmp/main-integration-full-test-suite.log`。
- JavaScript 5 tests、zeitwerk、Ruby/JavaScript構文検査、差分検査: すべて成功。
- GitHubのmain、Render、本番データは変更していない。push・PR・正本へのマージ・デプロイは未実施。推薦コア `4d8d2ea` はこの不具合修正の対象に含めていない。

## 固定した評価レポート

| 評価 | 固定レポート | SHA256 |
|---|---|---|
| 初回 2026-09-14 21:53:44〜21:57:59 JST | `/Users/user/.codex/ai-fix-handoffs/chronoflow/1204daf0b1d8694edec93ad4e093f88f41bebe2e64fdc8a49fc21980fce2a376/report.md` | `1204daf0b1d8694edec93ad4e093f88f41bebe2e64fdc8a49fc21980fce2a376` |
| 最新 2026-09-17 19:28:11〜19:28:35 JST | `/Users/user/.codex/ai-fix-handoffs/chronoflow/0bdee8a80a7d21126c72746092d88e980604445baf93f9f85cf1688ef3358b79/report.md` | `0bdee8a80a7d21126c72746092d88e980604445baf93f9f85cf1688ef3358b79` |

両ファイルのハッシュを照合した。原文はテストデータとして使用。9/14の16ケース中11 FAIL、9/17の17ケース中9 FAILは評価項目数であり、独立した原因数ではない。9/17のCF-03・02b・02dの日時PASSを、初回月曜条件の改善証拠にはしていない。

## 再現方法と原因の整理

基準コミットの `Ai::Client` を別ロードして修正前を再現し、修正後と同じ原文fixture・空の合成予定contextを使って比較した。時計は初回 `2026-09-14T21:57:59+09:00`、最新 `2026-09-17T19:28:35+09:00`、いずれも `Asia/Tokyo` に固定。新規回帰は外部AIアクセスを検知するスタブを入れ、ローカル解釈経路で完結すること、Event件数が変わらずtool_invocationsが空であることも検証した。AIモデル全般や本番の内部構成についての検証ではない。

原因は以下へ集約した。

1. 集中作業の候補日計算で、月曜の「来週」起点が当日になり、「翌週」が再来週として扱われていた。過去日時確認より先に集中作業経路が応答していた。
2. 補足文・保存通知禁止を予定またはリマインダーとして採用し、複数依頼が予定ごとに分離されなかった。説明依頼専用の判定もなかった。
3. 英語のtomorrow/day after tomorrow/today、minute/hour表現を既存の日時・長さ解析へ渡せていなかった。14:00自体の時計解析だけでなく日付・補足文の扱いも関係していた。
4. 明示名の抽出より活動種別や指示語除去が優先され、集中作業名の汎化、繰り返し名への入力指示混入が起きた。指定名が指示語で終わる場合にも、カードと内包予定の同一性を保つよう修正した。
5. 繰り返しは基準版からpayload.eventsに16件を生成していたが、UIが先頭日時しか表示していなかった。未生成・保存失敗の問題ではなかった。
6. 補足否定を正しく扱った際、既存の曜日矛盾検証が「2026年9月18日」の末尾「日」を日曜と誤認することが表面化した。日付末尾と指定曜日を分けて修正した。

## ケースごとの対応と検証結果

次表の日時は9/17 19:28:35 JST基準。9/14条件も別fixtureで維持した。

| ケース | 基準版の再現・原因 | 修正後のローカル結果／残る制約 |
|---|---|---|
| CF-01 | 日時保持、名称だけ集中作業に汎化 | 指定名をカード・payloadへ保持、9/18 15:00〜15:30を1件。初回9/15も保持 |
| CF-02 | 2件の時刻・長さを混ぜて9/22 18:00〜19:00の1件 | 過去の休憩9/17 18:00を名称付きで説明して候補から除外、未来の集中作業9/22 10:00〜11:00を独立して保持。初回9/14でも同様に分離 |
| CF-02a | 表示希望の補足を別予定として時間不足エラー | 補足を予定化せず、今日18:00が過去であることを説明、候補なし |
| CF-02b | 9/17基準の9/22は元からPASS。月曜9/14基準は9/15となりFAIL | 月曜基準も9/22 10:00〜11:00へ修正。曜日別の来週・翌週・再来週も確認 |
| CF-02c | 今日18:00〜18:30を無警告で提案 | 過去時刻を明記して候補を出さない。探索枠でも現在より前の開始を除外 |
| CF-02d | 9/17の来週金曜9/25は元からPASS | 9/25 10:00〜11:00を維持。9/18と区別、名称も保持 |
| CF-03 | 9/17の来週内3候補は元PASS。9/14は当日の過去枠 | 両基準で来週内に3代替案。未指定の90分・9〜18時・平日という仮定を追加説明。代替案相互の重なりは重複登録と扱わない |
| CF-04a | 元PASS: 11/31を拒否 | 存在しない日付として拒否、候補なしを維持 |
| CF-04b | 元PASS: 25:30を拒否。例示は翌1:00 | 拒否を維持し、条件付き例を「翌日1時30分」へ改善。自動変換の修正とは扱わない |
| CF-04c | 元PASS: 同日11:00〜10:00を拒否 | 自動の翌日化なし、候補なしを維持 |
| CF-05 | 保存通知禁止をリマインダーと誤解釈 | 指定名、日本語説明、9/18 14:00〜14:20の休憩候補。英語語彙変換は引用名の外に限定 |
| CF-05R | 補足変更後も日付・時間不足扱い | CF-05と同じ日時・長さ・指定名を保持。否定語だけが唯一の原因ではないことを対照確認 |
| CF-06 | 指示文が名称に混入。16件生成済みだが期間と全日時を確認できない | 指定名、火木07:00〜07:10の16件、9/22〜11/12を保持。回答とカードに期間・件数、カードに表示TZ、展開一覧に全日時・名称。初回9/15〜11/5も確認。確定保存は未実施 |
| CF-07a | 元PASS: 空欄・空白未送信 | JSと隔離ローカルUIで両状態disabledを確認。送信ガードは変更していない |
| CF-07b | 1,000文字の日時と背景除外は成功、名称のみ欠落 | 全1,000文字を保持したfixtureで、9/20 15:00〜15:30・指定名・背景除外を確認。初回9/17も保持。長文固有の欠陥とは扱わない |
| CF-08 | 元PASS: 処理中・重複抑止・日時保持。名称欠落は共通所見 | 9/21 16:00〜16:30の1候補と名称を確認。初回原文で実UIの相談中disabled→追加Enter→入力/回答/候補各1件を確認。遅延応答を保持したJSテストでもAPI1回を確認 |
| CF-09 | 説明依頼をリマインダーとして対象予定を要求 | 対応範囲と非対応時の案内を日本語で説明、候補/操作なし。引用名の「説明して」や否定説明要求を説明実行と誤認しないテストも追加 |

対象FAILに未解決のローカル再現は残っていない。公開版とのコミット一致は未確認で、公開版への修正反映・改善は主張しない。

## 変更ファイル

- `app/services/ai/client.rb`: 相対週・過去時刻、複数予定と補足否定の分離、英語日時語、説明意図、明示名の保持、繰り返し期間、25:30の例示、日付末尾と曜日の分離。
- `app/javascript/application.js`: bundle候補の全件数・期間・表示TZ、全件の折りたたみ一覧、追加件数表示。日跨ぎ終了日も表示、名称はエスケープ。
- `app/assets/stylesheets/application.css`: 一覧の最小書式。
- `test/fixtures/ai_september_eval.json` と `test/fixtures/ai_september17_eval.json`: レポートの原文・基準時計・SHAを保持。
- `test/services/ai_client_september*_test.rb`: 原文回帰、週境界、過去枠、名称・引用・肯定否定の境界を検証。候補と機能説明の併記、名称内の「昨日」「先週」も別テストで確認。
- `test/javascript/ai_chat_ui_test.mjs`: 全16件表示、期間、単一候補、エスケープ、空欄・処理中・重複送信抑止の5テスト。

## 検査結果

- 9/14原文: 修正前16 tests / 130 assertions / 13 failures。13件は元の11 FAILと、P3の25:30例示・CF-08名称の追加検査2件。元評価PASSをFAILへ読み替えていない。修正後16 tests / 370 assertions / 0 failures。
- 9/17原文: 修正前21 tests / 212 assertions / 13 failures。13件は元の9 FAILとCF-03/08/02b/02dの追加名称検査4件。元の日時等のPASS基準を別テストで維持。修正後21 tests / 415 assertions / 0 failures。
- 日時境界8 tests / 105 assertions、最終の入力制御12 tests / 218 assertionsともPASS。新規サービス回帰は合計57 tests。
- 最終全Ruby: **482 tests / 22,878 assertions / 0 failures / 0 errors / 0 skips**。契約照合・controller・model・integration・既存AI回帰を含めて全実行。ログ: `tmp/final-482-test-suite.log`。
- JavaScript: 5 tests / 0 failures。rendererと送信ハンドラーの実コードをNode VMで読み、応答保留中の再submitも検証。
- `rails zeitwerk:check`、Ruby/JavaScript構文検査、`git diff --check`: PASS。
- 契約照合: 当初はLinuxの既定パス不在、続いて実在repoで固定commit不在を確認。再開依頼の取得許可に従い、`/Users/user/projects/ai_secretary_home` の既知originから `c3ff4e3033f2d499696896fa0624069484cd4387` のobjectを取得。`--no-tags --no-write-fetch-head --no-auto-maintenance` を用い、HEAD・ブランチ・作業ファイルを保持。`AI_SECRETARY_HOME_REPOSITORY=/Users/user/projects/ai_secretary_home` で4schemaのバイト照合を含む7 tests / 65 assertionsがPASSとなり、以前の環境失敗は解消した。
- 既存のRack `:unprocessable_entity` 非推奨警告は残るが検査失敗ではない。本修正の対象外。


環境はRuby 3.2.2 / Rails 7.1.6 / PostgreSQL。test railtieが既存設定で無効のため、Rubyから各testファイルをrequireする既存構成に沿って実行した。検査を通すためのGemfile.lock更新、検査除外、期待値の弱体化はしていない。

```sh
export PATH=/Users/user/.rbenv/versions/3.2.2/bin:$PATH
export RAILS_ENV=test
export DATABASE_URL=postgresql:///chronoflow_ai_fix_20260914_222701
export AI_SECRETARY_HOME_REPOSITORY=/Users/user/projects/ai_secretary_home
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
node --test test/javascript/ai_chat_ui_test.mjs
bundle exec rails zeitwerk:check
ruby -c app/services/ai/client.rb
node --check app/javascript/application.js
git diff --check
```

## 実画面とデータの境界

隔離DB `chronoflow_ai_fix_ui_20260914_222701`、ローカル `127.0.0.1:43271`、架空UserでCF-06/07a/08を確認した。初回時計条件に対応する9/15〜11/5の16日付を全件展開し、末尾までスクロールして確認。AI接続先は `http://127.0.0.1:1` に固定し、対象入力はローカル経路で処理。初期更新の接続不可表示はこの隔離設定によるもので、公開障害の再現ではない。

予定追加等の確定操作は行っていない。最終の隔離UI DBはEvent=0 / EventReminder=0 / Notification=0。試験中の合成会話・候補のみ残した。検証Pumaとタブは終了済み。テストDBとUI DBは専用名で残し、既存DBの初期化・削除はしていない。

## 未実施・次回公開評価

- 公開の確定保存・繰り返し実レコード・重複・通知、個人予定との実競合、自然な通信障害・再送・フォールバックは未実施。未観測を合格や既知不具合にしていない。
- モバイル、長文上限、全幅の文字切れ、連打全般、AIモデルの一般的な品質は未保証。
- 公開へ別途反映された後、CF-01/02/02a/02c/05/05R/06/07b/09を候補表示まで再確認。CF-06は全件一覧の開閉と各火木の時刻まで確認する。
- CF-03/04a/04b/04c/07a/08/02b/02dも回帰確認。実行日のAsia/Tokyoと実送信時刻を残し、「明日」「来週」と絶対日付を更新する。過去枠ケースは実際に終了した時刻に設定する。
- 月曜→来週火曜の条件は月曜に再評価するか固定時計のローカル回帰を併用。9/17の火曜PASSだけで初回問題の解消とはしない。

## ローカル詳細証拠

- `tmp/ai-september-eval/baseline_outputs.json` / `baseline_test.txt`: 9/14原文の修正前出力と赤テスト。
- `tmp/ai-september-eval/fixed_outputs.json`: 9/14原文の修正後出力。
- `tmp/ai_fix_ui_evidence_20260914.md`: 初回条件の実UI確認詳細。
- `tmp/ai-september17-eval/baseline_outputs.json` / `baseline_test.txt`: 9/17原文の修正前出力と赤テスト。
- `tmp/ai-september17-eval/current_outputs.json` / `current_test.txt`: 9/17原文の修正後出力・検査結果。
- 最終全体検査ログの所在は結果欄へ記載。

最新と従来のdispatch.jsonに、このレポートの絶対パス、最終状態、実装とレポートのコミットを記録する。実装10ファイルは追加1,200行・削除16行（うちアプリ本体は3ファイル、残りは固定原文fixtureと回帰テスト）。
