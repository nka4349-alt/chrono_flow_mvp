# ChronoFlow 日英混在の休憩候補への相手混入修正

## 対象と再現条件

- 元レポート: `/Users/user/Documents/Codex/2026-09-14/chronoflow-ai-test/outputs/2026-09-18T19-25-19+0900.md`。公開ブラウザ評価18ケース中16 PASS、CF-05とCF-05Rの2 FAIL。
- 原文SHA-256: `e58211e571ca5b85798786d92e0e838d0a9b041c7a69b272e9b311d4503b1e9a`。原本は変更せず、専用handoffディレクトリへ固定保存。
- 基準コミット: `c353bcb6f640250d4ff87324636dce7102953acd`。
- 修正ブランチ: `codex/chronoflow-mixed-language-participant-fix-20260918`。
- 時計: `2026-09-18T19:18:00+09:00`、`Asia/Tokyo`。既存予定は空。連絡先なし／合成連絡先・友人ありを比較する。
- 実ユーザーの連絡先は読んでいない。以下は合成連絡先`k`で公開報告と同じ症状を再現した結果であり、公開リクエストの実contextを採取したものではない。

CF-05原文:

```text
Please suggest a 20-minute break tomorrow at 14:00. 名前は「CF-05 テスト休憩」、説明は日本語でお願いします。候補だけを表示し、保存や通知はしないでください。
```

CF-05R原文:

```text
Please suggest a 20-minute break tomorrow at 14:00. 名前は「CF-05R テスト休憩」、説明は日本語でお願いします。候補の表示だけを希望します。
```

## 原因と修正

既知連絡先名の判定が部分文字列検索だったため、`break`の末尾の`k`を相手指定として拾っていた。連絡先`a`は冠詞、`at`は時刻前の単語、`Ann`は`planning`内で同様に誤認した。連絡先が空の検証では発現しない。

Latin文字を含む既知名は、名前の境界と参加者指定の文脈を両方要求する。`Kと会議`、`with k`、`相手は「Alice」`、`with Alice and Bob`、`Alice、Bobと会議`を保持し、明示した引用タイトル内の名前は参加者判定から外す。大文字・小文字だけが異なる重複名も統合する。既存の日本語名抽出は維持する。

表示文だけでなく、候補の`contact_name`、`participant_names`、`relation_tags`、`payload.events`内の予定名・説明も対象とする。誤った相手が空き時間判定へ渡る経路も同じ抽出処理で修正される。

レビュー中に多数の連絡先で正規表現の再生成が遅くなる点を修正した。本文に出る既知名だけでパターンを作り、参加者一覧の判定パターンは名前ごとのループの外で一度生成する。

## 結果と回帰確認

CF-05／CF-05Rは、指定した名前と9/19 14:00〜14:20を保持し、未指定の相手情報が全階層で空になる。

- 修正前: 18 tests / 353 assertions / 11 failures / 0 errors。報告の2原文を含めて再現。
- 参加者回帰: 2原文×6 context（空、contact k、friend k、a、at、50連絡先）、単語内のAnn、引用タイトル、明示した相手、複数相手、引用名、日本語名。全ケースで外部AIを禁止し、Event増加なし・tool_invocations空を確認。
- 原文比較: 未送信CF-07aとCF-06の重複再送を整理した17原文×2 context×基準版／修正版の68出力、172確認PASS。空contextでは17件すべて完全一致。合成kありではCF-05／CF-05R以外の15件が全フィールド完全一致。修正版では全17件で空contextと合成kありの出力が一致する。
- 長文CF-07bの原文1,000文字、CF-06の火木16予定（9/22〜11/12、07:00〜07:10）を保持。
- 独立レビュー: リスト・引用・敬称を含む6入力で既知参加者を保持。50連絡先のCF-05は基準版316 ms／修正版313 ms。50名すべてを本文に列挙すると1.68秒／2.58秒で、既存の4人制限と選出結果は同じ。時間は起動を除くローカル単発計測であり、性能保証ではない。
- 最終全Ruby: **525 tests / 24,196 assertions / 0 failures / 0 errors / 0 skips**。新規参加者回帰22件と既存のSpecialist契約照合を含む。
- JavaScript: 5 tests / 0 failures。Zeitwerk、Ruby構文、差分検査成功。
- GitHub Actionsは0件、mainは保護なし。ローカル検証結果をCI成功とは表記しない。

環境: Ruby 3.2.2、RAILS_ENV=test、専用DB `chronoflow_ai_fix_20260918_participant`、AI_SECRETARY_HOME_REPOSITORY=`/Users/user/projects/ai_secretary_home`。元の専用DBがなくなっていたため、新規テストDBの作成成功後にschemaをロードした。本番DBは使っていない。

全Rubyの実行コマンド:

```sh
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
```

詳細ログ・合成出力はローカルの`tmp/participant-boundary/`に保存。`baseline-test.log`、`final-full-test-suite.log`、`september18_comparison.md`、`september18_comparison.json`、`independent-review-20260918.json`を参照。

## 公開反映

デプロイ前の統合まで行う。2026-09-18の読み取り確認ではRenderのsourceはmain、LIVEは`c353bcb`、Auto-Deploy・PR PreviewsともOffだった。PRタイトル・push先端・mergeコミットに`[skip render]`を指定する。Render設定、環境変数、DB構造は変更しない。

公開へのデプロイ、公開予定の確定保存、通知、外部AI呼び出しは行っていない。未デプロイのため、公開ブラウザで18件すべて合格したとは判定しない。公開後にCF-05／CF-05Rを候補表示まで再評価し、指定名・翌日14:00〜14:20・相手欄なしを確認する。
