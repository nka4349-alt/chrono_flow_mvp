# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'date'

module Ai
  class Client
    DEFAULT_TIMEOUT = 20

    LIST_ITEM_MARKER_TOKEN_PATTERN = /
      (?<![0-9０-９])
      (?<number>[0-9０-９]{1,2})
      (?<marker>
        [)）、] |
        [.．](?![0-9０-９]) |
        [.．](?=[0-9０-９]{1,2}(?:[:：][0-9０-９]{2}|時(?!間)|じ(?![ \t]*(?:間|かん))))
      )
      [ \t　]*
    /x.freeze
    LIST_ITEM_BOUNDARY_LITERALS = [
      'それから', 'そして', "\r\n", "\n",
      ':', '：', "\uFE13", "\uFE55",
      '、', "\uFE11", "\uFE51", '､',
      '。', "\uFE12", '｡',
      ',', '，', "\uFE10", "\uFE50",
      ';', '；', "\u037E", "\uFE14", "\uFE54"
    ].sort_by { |literal| -literal.bytesize }.freeze
    NFKC_HORIZONTAL_SPACE_LITERALS = [
      "\u00A0", "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005", "\u2006",
      "\u2007", "\u2008", "\u2009", "\u200A", "\u202F", "\u205F", "\u3000"
    ].sort_by { |literal| -literal.bytesize }.freeze
    RAW_HORIZONTAL_SPACE_CHARACTERS = [' ', "\t", *NFKC_HORIZONTAL_SPACE_LITERALS].freeze
    SCHEDULE_SYNTAX_PERIOD_BOUNDARY_CHARACTERS = ['.', '．', "\uFE52", "\u2024"].freeze
    NFKC_PERIOD_PATTERN = /[.．﹒․]/.freeze
    SCHEDULE_SYNTAX_CLAUSE_BOUNDARY_CHARACTERS = (
      LIST_ITEM_BOUNDARY_LITERALS.select do |literal|
        literal.length == 1 && ![':', '：', "\uFE13", "\uFE55"].include?(literal)
      end +
      SCHEDULE_SYNTAX_PERIOD_BOUNDARY_CHARACTERS +
      ['!', '！', "\uFE15", "\uFE57", '?', '？', "\uFE16", "\uFE56"]
    ).uniq.freeze
    SCHEDULE_SYNTAX_COMMA_BOUNDARY_CHARACTERS = [
      ',', '，', "\uFE10", "\uFE50", '、', "\uFE11", "\uFE51", '､'
    ].freeze
    SCHEDULE_SYNTAX_MULTI_CHARACTER_BOUNDARIES = %w[そして それから].freeze
    SCHEDULE_SYNTAX_CLAUSE_BOUNDARY_CHARACTER_CLASS = Regexp.escape(
      SCHEDULE_SYNTAX_CLAUSE_BOUNDARY_CHARACTERS.reject { |character| character.match?(/\s/) }.join
    ).freeze

    LIST_CONTINUATION_PREFIX_PATTERN = /
      (?:\A|\r?\n)
      [ \t　]*
      (?:
        前回の予定候補の続き |
        予定候補の続き |
        予定一覧の続き |
        前回の続き |
        続き
      )
      [ \t　]*
      [:：]?
      \z
    /x.freeze

    LIST_NONCONTINUATION_PREFIX_PATTERN = /
      (?:\A|\r?\n)
      [ \t　]*
      (?:
        前回の予定候補の続き |
        予定候補の続き |
        予定一覧の続き |
        前回の続き |
        続き
      )
      (?:について|に関して)
      [ \t　]*
      [:：]?
      \z
    /x.freeze

    MULTI_EVENT_TERMINAL_FRAMING_PATTERN = /
      [ \t　]*
      (?:
        の[ \t　]*予定候補[ \t　]*を[ \t　]*
        (?:
          作って(?:[ \t　]*(?:ください|下さい))? |
          作る |
          作成して(?:[ \t　]*(?:ください|下さい))?
        )
        |
        を[ \t　]*
        (?:(?:\d+(?:\.\d+)?[ \t　]*(?:時間[ \t　]*半|時間(?:[ \t　]*\d+[ \t　]*分)?|分))[ \t　]*の[ \t　]*)?
        予定候補[ \t　]*として[ \t　]*
        (?:
          整理して(?:[ \t　]*(?:ください|下さい))? |
          整理する |
          まとめて(?:[ \t　]*(?:ください|下さい))? |
          まとめる
        )
      )
      [ \t　]*
      (?:[。.！!？?][ \t　]*)?
      \z
    /x.freeze

    NEGATIVE_DURATION_SIGN_PATTERN = /[-−﹣－]/.freeze
    NEGATIVE_DURATION_EXPRESSION_PATTERN = /
      (?<sign>#{NEGATIVE_DURATION_SIGN_PATTERN.source})
      [ \t　]*
      (?<value>\d+(?:\.\d+)?|\.\d+)
      [ \t　]*
      (?<unit>時間|分)
    /x.freeze
    SIGNED_OR_UNSIGNED_DURATION_EXPRESSION_PATTERN = /
      (?:#{NEGATIVE_DURATION_SIGN_PATTERN.source}[ \t　]*)?
      (?:\d+(?:\.\d+)?|\.\d+)
      [ \t　]*
      (?:時間|分)
    /x.freeze
    EXPLICIT_DATE_COMPONENT_PATTERN = /
      (?:(?<year>\d{4})年)?
      (?<month>\d{1,2})
      (?:月|[\/.\-．])
      (?<day>\d{1,2})日?
    /x.freeze
    EXPLICIT_DATE_LABEL_LITERALS = %w[
      日付 日時 開始日 終了日 予定日 予約日 提出日 実施日 開催日
      希望日 利用日 締切 締切日 締切り 締切り日 締め切り 締め切り日
      予約 提出 開催 実施 利用 希望 次回 開始 終了 予定
      誕生日 公開日 発売日 更新日 作成日 変更日 登録日 納品日
      支払日 支払い日 受取日 受け取り日 出発日 到着日 訪問日
      面接日 試験日 受診日 診察日 期日 期限 納期
    ].sort_by { |literal| -literal.bytesize }.freeze
    EXPLICIT_DATE_LABEL_PARTICLES = ['は', 'が', 'を', 'の', ':', '：', '=', '＝'].freeze
    SCHEDULE_SYNTAX_ACTION_PATTERN = /
      変更 | 移動 | ずらして | ずらす | ずらしたい | リスケ | 延期 | 前倒し |
      削除 | 消して | 消す | 消したい | 消去 | なくして | 取り消し | キャンセル |
      確認 | チェック | 追加 | 登録 | 入れて | 入れる | 入れたい | いれて | いれる | いれたい |
      作って | 作る | 作成 | 作りたい | 確保 | 予約(?:して|する|したい)
    /x.freeze
    SCHEDULE_SYNTAX_SCOPE_INTENT_PATTERN = /
      #{SCHEDULE_SYNTAX_ACTION_PATTERN.source} |
      教えて | 見せて | まとめて | 整理 | 調整 | 予約
    /x.freeze
    SCHEDULE_SYNTAX_ACTIVITY_PATTERN = /
      予約 | 会食 | 歯医者 | 歯科 | 美容院 | 美容室 | 理容 | 散髪 |
      面接 | 面談 | 商談 | 授業 | 講義 | 試験 | 診察 | 健診 | 検診 |
      通院 | 病院 | 会議 | ミーティング | 打ち合わせ | 打合せ |
      集中作業 | ディープワーク | 作業時間 | レビュー時間 | 課題時間 |
      宿題 | 復習 | ストレッチ | 体操 | 休憩 |
      電話 | 作業 | 資料作成 | メモ整理 | レビュー | 飲み会 | 飲み | 食事 |
      旅行 | 出張 | 滞在 | 観光 | 宿泊 | 帰省 | 休み | 休暇 |
      勉強 | 学習 | 課題 | チャット | 営業 | 定例 | 会う | 相談 |
      挨拶 | 掃除 | 買い物 | 洗濯 | 散歩 | 運動 | ランチ | ディナー |
      映画 | 読書 | 予定 | 日程 | スケジュール | カレンダー | イベント
    /x.freeze

    MULTI_EVENT_EXECUTION_ACTION_PATTERN = /
      [ \t　]*
      (?:を[ \t　]*)?
      (?:(?:各[ \t　]*)?(?:#{NEGATIVE_DURATION_SIGN_PATTERN.source})?\d{1,3}(?:\.\d+)?[ \t　]*(?:時間[ \t　]*半|時間|分)[ \t　]*)?
      (?:行います|行う|実施します|実施する|予定です)
      [ \t　]*
      (?:[。.！!？?][ \t　]*)?
      \z
    /x.freeze

    PROTECTED_TEXT_DELIMITER_PAIRS = {
      '「' => '」', '『' => '』', '“' => '”', '‘' => '’',
      '"' => '"', "'" => "'", '（' => '）', '(' => ')',
      '［' => '］', '[' => ']', '【' => '】'
    }.freeze
    PROTECTED_TEXT_ASYMMETRIC_CLOSINGS = PROTECTED_TEXT_DELIMITER_PAIRS
      .reject { |opening, closing| opening == closing }
      .invert
      .freeze

    NUMERIC_QUALIFIER_TEMPORAL_LABEL_PATTERN = /
      (?:
        今日|きょう|明日|あした|明後日|あさって|
        昨日|きのう|一昨日|おととい|翌日|翌朝|
        (?:\d+|一|二|三|四|五|六|七|八|九|十|十一|十二|十三|十四|十五|十六|十七|十八|十九|二十)
        (?:日|にち)後|
        (?:再来月|来月|翌月|今月)の?最終[月火水木金土日](?:曜日|曜)?|
        毎月第[1-5一二三四五][月火水木金土日](?:曜日|曜)?|
        毎月(?:3[01]|[12]\d|0?[1-9])日|
        (?:(?:来月|翌月|今月)の?)?第[1-5一二三四五][月火水木金土日](?:曜日|曜)?|
        (?:毎週|隔週)[ \t　]*[月火水木金土日](?:曜日|曜)?|
        (?:(?:再来週|来週|翌週|今週|次の)の?[ \t　]*)?[月火水木金土日](?:曜日|曜)|
        (?:(?:再来週|来週|翌週|今週)の?(?:週末|末|土日)|(?:週末|土日))|
        (?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])月(?:3[01]|[12]\d|0?[1-9])日?|
        (?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])[\/.\-．](?:3[01]|[12]\d|0?[1-9])日?|
        (?<!\d)(?:3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])|
        先々週|先週|再来週|来週|翌週|今週|
        来月頭|先々月|先月|再来月|来月|翌月|今月|月末|月初|
        一昨年|去年|昨年|
        毎日|毎朝|毎晩|毎週|隔週|毎月|平日|
        gw中|gw明け|ゴールデンウィーク中|ゴールデンウィーク明け|連休明け|
        終日|一日中|1日中|丸一日|まる一日|全日|all[ \t]*day|
        午前中|午前|午後|朝イチ|朝一|朝|正午|夕方|放課後|深夜|未明|
        今夜|今晩|夜|よる|お昼|昼|am|pm
      )
    /ix.freeze
    NUMERIC_QUALIFIER_TEMPORAL_ANCHOR_PATTERN = /
      #{NUMERIC_QUALIFIER_TEMPORAL_LABEL_PATTERN.source}
      (?:[ \t　]*(?:は|に|で|の|から|まで|頃|ごろ|以降|以前|開始|間|中)){0,3}
      \z
    /ix.freeze
    NUMERIC_QUALIFIER_TEMPORAL_BODY_START_PATTERN = /
      \A#{NUMERIC_QUALIFIER_TEMPORAL_LABEL_PATTERN.source}
    /ix.freeze
    NUMERIC_QUALIFIER_PERIOD_BODY_START_PATTERN = /
      \A(?:
        終日|一日中|1日中|丸一日|まる一日|全日|all[ \t]*day|
        午前中|午前|午後|朝イチ|朝一|朝|正午|夕方|放課後|深夜|未明|
        今夜|今晩|夜|よる|お昼|昼|am|pm
      )
    /ix.freeze
    NUMERIC_LIST_MARKER_LOOKAHEAD_BYTES = 512

    CLOCK_TOKEN_PATTERN = /
      (?<![\d〇零一二三四五六七八九十百千万億])
      (?:(?<period>午前中|午前|午後|朝|深夜|未明|今夜|今晩|夕方|放課後|夜|よる|お昼|昼|am|pm)[ \t]*)?
      (?:
        (?<colon_hour>\d{1,2})[:：](?<colon_minute>\d{2})(?!\d)
        |
        (?<arabic_hour>\d{1,2})[ \t]*(?:時(?![ \t]*間)|じ(?![ \t]*(?:間|かん)))
        (?:
          (?<arabic_half>半)
          |
          (?<arabic_numeric_minute>\d+)[ \t]*分
          |
          (?<arabic_numeric_minute_without_unit>\d{2})(?!\d|[ \t]*時間)
          |
          (?<arabic_kanji_minute>[〇零一二三四五六七八九十百千万億]+)[ \t]*分
        )?
        |
        (?<kanji_hour>[〇零一二三四五六七八九十百千万億]+)[ \t]*(?:時(?![ \t]*間)|じ(?![ \t]*(?:間|かん)))
        (?:
          (?<kanji_half>半)
          |
          (?<kanji_numeric_minute>\d{1,2})[ \t]*分
          |
          (?<kanji_kanji_minute>[〇零一二三四五六七八九十百千万億]+)[ \t]*分
          |
          (?=\z|[ \t、。,;；・･]|に|の|から|まで|頃|ごろ|開始|〜|~|-|と|\d+(?:\.\d+)?[ \t]*時間)
        )
      )
    /ix.freeze

    GARBAGE_KEYWORDS = %w[
      ゴミ出し ごみ出し ゴミ捨て ごみ捨て
      ゴミ ごみ 可燃ごみ 燃えるごみ 資源ごみ 不燃ごみ
    ].freeze

    WEEKDAY_MAP = {
      '日' => 0, '日曜' => 0, '日曜日' => 0,
      '月' => 1, '月曜' => 1, '月曜日' => 1,
      '火' => 2, '火曜' => 2, '火曜日' => 2,
      '水' => 3, '水曜' => 3, '水曜日' => 3,
      '木' => 4, '木曜' => 4, '木曜日' => 4,
      '金' => 5, '金曜' => 5, '金曜日' => 5,
      '土' => 6, '土曜' => 6, '土曜日' => 6
    }.freeze

    WEEKDAY_LABELS = {
      0 => '日曜',
      1 => '月曜',
      2 => '火曜',
      3 => '水曜',
      4 => '木曜',
      5 => '金曜',
      6 => '土曜'
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(context:, user_message:, refresh_only: false)
      @context = context
      @user_message = user_message.to_s
      @refresh_only = refresh_only
    end

    def call
      syntax_response = local_schedule_syntax_clarification_response(@user_message)
      return secretary_labels(syntax_response) if syntax_response

      recurrence_response = monthly_garbage_recurrence_response
      return secretary_labels(recurrence_response) if recurrence_response

      structured_response = local_structured_schedule_response
      return secretary_labels(apply_user_text_title_overrides(structured_response)) if structured_response

      secretary_labels(apply_user_text_title_overrides(request_remote))
    rescue StandardError => e
      secretary_labels(fallback_response(e))
    end

    private

    def monthly_garbage_recurrence_response
      text = normalize_japanese(@user_message)
      return nil unless context_value(:scope).to_s == 'home'
      return nil unless GARBAGE_KEYWORDS.any? { |keyword| text.include?(normalize_japanese(keyword)) }
      return nil if invalid_explicit_date_match(text) ||
                    invalid_explicit_time_match(text) ||
                    invalid_explicit_time_range_match(text) ||
                    invalid_duration_match(text)

      now = context_now
      year, month = target_year_month(text, now)
      weekdays = target_weekdays(text)

      return nil unless year && month && weekdays.any?

      dates = dates_for_month_weekdays(year, month, weekdays, now.to_date)
      return nil if dates.empty?

      label = "#{month}月の#{weekdays.map { |weekday| WEEKDAY_LABELS[weekday] }.join('・')}"

      event_payloads = dates.first(10).map do |date|
        start_at = app_time_zone.local(date.year, date.month, date.day, 0, 0, 0)
        end_at = start_at + 1.day

        {
          'title' => 'ゴミ出し',
          'description' => 'AI秘書提案の予定候補',
          'start_at' => start_at.iso8601,
          'end_at' => end_at.iso8601,
          'all_day' => true,
          'color' => '#64748b',
          'category' => 'personal',
          'intent' => 'errand',
          'schedule_profile' => 'errand',
          'target_date' => date.iso8601
        }
      end

      date_labels = event_payloads.map do |payload|
        begin
          Date.iso8601(payload['target_date']).strftime('%-m/%-d')
        rescue StandardError
          payload['target_date']
        end
      end.join('、')

      recommendations = [
        {
          'kind' => 'draft_event',
          'title' => "ゴミ出し（#{label}）",
          'description' => "#{date_labels} にゴミ出し",
          'reason' => "#{label}のゴミ出しを1件のまとめ候補にしました。追加すると各日に予定を作成します。",
          'start_at' => event_payloads.first['start_at'],
          'end_at' => event_payloads.first['end_at'],
          'all_day' => true,
          'payload' => {
            'title' => "ゴミ出し（#{label}）",
            'description' => "#{date_labels} にゴミ出し",
            'start_at' => event_payloads.first['start_at'],
            'end_at' => event_payloads.first['end_at'],
            'all_day' => true,
            'color' => '#64748b',
            'category' => 'personal',
            'intent' => 'errand',
            'schedule_profile' => 'errand',
            'rank_position' => 1,
            'recurrence_kind' => 'monthly_weekdays',
            'recurrence_label' => label,
            'target_dates' => event_payloads.map { |payload| payload['target_date'] },
            'events' => event_payloads
          }
        }
      ]

      {
        assistant_message: "#{label}のゴミ出しを1件のまとめ候補にしました。追加すると各日に予定を作成します。",
        recommendations: recommendations,
        provider: 'rails-garbage-recurrence-v1',
        policy_run: {
          provider: 'rails-garbage-recurrence-v1',
          policy_version: 'rails-garbage-recurrence-v1',
          route: 'rails_preprocessor',
          request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
          prompt_snapshot: {
            user_message: @user_message,
            refresh_only: @refresh_only,
            scope: context_value(:scope)
          },
          context_snapshot: {
            scope: context_value(:scope),
            timezone: context_value(:timezone),
            now: context_value(:now)
          },
          result_metadata: {
            recommendation_count: recommendations.length,
            recurrence_label: label,
            bundled_event_count: event_payloads.length
          }
        },
        tool_invocations: []
      }
    end


    # === CF_LOCAL_STRUCTURED_AI_V5 ===

    def local_structured_schedule_response
      return nil unless context_value(:scope).to_s == 'home'
      return nil if @refresh_only

      text = normalize_japanese(@user_message)
      return nil if text.blank?
      return nil if schedule_syntax_delimiter_scan(@user_message)[:error]

      schedule_clauses = nil

      invalid_explicit_date_response(text) ||
        invalid_explicit_time_response(text) ||
        invalid_time_range_response(text) ||
        local_negative_reminder_response(text) ||
        invalid_duration_response(text) ||
        local_temporal_contradiction_response(text) ||
        local_memory_save_response(text) ||
        local_schedule_summary_response(text) ||
        local_schedule_organization_response(text) ||
        local_numbered_list_clarification_response(text) ||
        local_weekday_multi_event_response(text) ||
        local_existing_event_delete_erase_response(text) ||
        local_between_existing_events_response(text) ||
        local_phase45_ambiguous_schedule_clarification_response(text) ||
        local_generic_schedule_clarification_response(text) ||
        local_short_activity_open_slot_response(text) ||
        local_ambiguous_schedule_clarification_response(text) ||
        local_recurrence_response(text) ||
        local_weekend_period_response(text) ||
        local_travel_time_assist_response(text) ||
        local_same_date_multi_explicit_time_response(
          text,
          clauses: (schedule_clauses ||= schedule_event_clauses(text))
        ) ||
        local_same_date_multi_time_response(text) ||
        local_focus_work_response(text) ||
        local_open_slot_response(text) ||
        local_event_reminder_response(text) ||
        local_existing_event_change_response(text) ||
        past_datetime_response(text) ||
        past_explicit_datetime_response(text) ||
        local_explicit_event_conflict_response(
          text,
          clauses: (schedule_clauses ||= schedule_event_clauses(text))
        ) ||
        local_single_explicit_event_response(text, require_explicit_time: true) ||
        local_availability_response(text) ||
        local_date_range_response(text) ||
        local_multi_event_response(
          text,
          clauses: (schedule_clauses ||= schedule_event_clauses(text))
        ) ||
        local_single_explicit_event_response(text)
    end

    def local_memory_save_response(text)
      normalized = normalize_japanese(text)
      return nil unless context_value(:scope).to_s == 'home'
      return nil if event_mutation_or_reference_request?(normalized)
      return nil if first_local_date_from_text(normalized) || explicit_time_present?(normalized)

      local_arrival_buffer_preference_memory_save_response(text) ||
        local_travel_route_memory_save_response(text) ||
        local_place_memory_save_response(text)
    end

    def local_place_memory_save_response(text)
      source = normalize_japanese_preserve_case(text)
      match = source.match(/\A(?<label>自宅|家|勤務先|職場|会社|よく使う駅|最寄り駅|ジム|病院|学校)\s*(?:は|=|＝|:|：)\s*(?<place>.+?)(?:です|だ|である)?\s*\z/)
      return nil unless match

      label = canonical_place_label(match[:label])
      kind = place_kind_for_label(label)
      place_name = clean_memory_value(match[:place])
      return nil if place_name.blank?

      build_memory_save_response(
        title: "#{label}を#{place_name}として保存",
        assistant_message: "#{label}を#{place_name}として記憶できます。保存しますか？",
        reason: "#{label}の場所メモリーとして保存候補を作成しました。",
        payload: {
          'memory_type' => 'user_place',
          'kind' => kind,
          'label' => label,
          'place_name' => place_name
        },
        provider: 'rails-local-memory-place-v1'
      )
    end

    def local_travel_route_memory_save_response(text)
      normalized = normalize_japanese_preserve_case(text)
      match = normalized.match(/\A(?<origin>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})から(?<destination>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})まで(?:の)?(?:移動(?:時間)?は?|所要時間は?)?\s*(?<minutes>\d{1,3})\s*分(?:です|だ)?\s*\z/)
      return nil unless match

      minutes = bounded_minutes(match[:minutes], min: 1, max: 300)
      return nil unless minutes

      origin_name = clean_memory_value(match[:origin])
      destination_name = clean_memory_value(match[:destination])
      return nil if origin_name.blank? || destination_name.blank?

      build_memory_save_response(
        title: "#{origin_name}から#{destination_name}まで#{minutes}分として保存",
        assistant_message: "#{origin_name}から#{destination_name}まで#{minutes}分として記憶できます。保存しますか？",
        reason: '移動時間メモリーとして保存候補を作成しました。',
        payload: {
          'memory_type' => 'user_travel_route',
          'origin_name' => origin_name,
          'origin_kind' => place_kind_for_label(origin_name),
          'destination_name' => destination_name,
          'travel_minutes' => minutes
        },
        provider: 'rails-local-memory-travel-route-v1'
      )
    end

    def local_arrival_buffer_preference_memory_save_response(text)
      source = normalize_japanese(text)
      match = source.match(/\A(?<target>会議|ミーティング|打ち合わせ|打合せ|商談|面談|病院|通院|旅行|出張|予定)\s*(?:は|なら|のときは|の時は)?\s*(?<minutes>\d{1,3})\s*分前(?:に)?(?:着きたい|到着したい|着く|到着)\s*\z/)
      return nil unless match

      minutes = bounded_minutes(match[:minutes], min: 0, max: 180)
      return nil unless minutes

      label = match[:target]
      key = "arrival_buffer.#{arrival_buffer_preference_key_for_label(label)}"

      build_memory_save_response(
        title: "#{label}の到着余裕を#{minutes}分前として保存",
        assistant_message: "#{label}は#{minutes}分前に着きたい設定として記憶できます。保存しますか？",
        reason: '到着バッファのメモリーとして保存候補を作成しました。',
        payload: {
          'memory_type' => 'ai_user_preference',
          'key' => key,
          'value' => minutes.to_s,
          'value_type' => 'integer'
        },
        provider: 'rails-local-memory-arrival-buffer-v1'
      )
    end

    def build_memory_save_response(title:, assistant_message:, reason:, payload:, provider:)
      {
        assistant_message: assistant_message,
        recommendations: [
          {
            'kind' => 'memory_save',
            'title' => title,
            'description' => 'AI秘書のメモリー保存候補',
            'reason' => reason,
            'all_day' => false,
            'payload' => payload.merge(
              'title' => title,
              'description' => 'AI秘書のメモリー保存候補',
              'source' => 'ai'
            )
          }
        ],
        provider: provider,
        policy_run: local_policy_run(provider, { recommendation_count: 1, memory_type: payload['memory_type'] }),
        tool_invocations: []
      }
    end

    def canonical_place_label(label)
      case normalize_japanese(label)
      when '家' then '自宅'
      when '職場', '会社' then '勤務先'
      else label.to_s.strip
      end
    end

    def place_kind_for_label(label)
      case normalize_japanese(label)
      when '自宅', '家' then 'home'
      when '勤務先', '職場', '会社' then 'work'
      when 'よく使う駅', '最寄り駅' then 'station'
      when 'ジム' then 'gym'
      when '病院', '通院' then 'hospital'
      when '学校' then 'school'
      else 'other'
      end
    end

    def arrival_buffer_preference_key_for_label(label)
      case normalize_japanese(label)
      when '会議', 'ミーティング', '打ち合わせ', '打合せ', '商談', '面談' then 'meeting'
      when '病院', '通院' then 'hospital'
      when '旅行' then 'travel'
      when '出張' then 'business_trip'
      else 'default'
      end
    end

    def clean_memory_value(value)
      clean_travel_place(value.to_s.gsub(/\s*(?:です|だ|である)\s*\z/, ''))
    end

    # 既存予定の変更・削除は、対象候補の検出まで。自動実行はしない。
    def local_same_date_multi_time_response(text)
      date = first_local_date_from_text(text)
      return nil unless date

      segments = same_date_time_segments(text)
      return nil unless segments.length >= 2

      events = segments.map do |segment|
        descriptor = local_event_descriptor(segment[:descriptor_text], fallback_title: segment[:activity_title])
        activity_title = segment[:activity_title].presence || descriptor[:activity_title]
        title = compose_local_event_title(activity_title, descriptor[:participant_names])

        start_at = local_time_at_minute(date, segment[:start_minute])
        next unless start_at

        end_at = if segment[:end_minute]
                   local_time_at_minute(date, segment[:end_minute])
                 else
                   start_at + segment[:duration_minutes].minutes
                 end
        next unless start_at && end_at && end_at > start_at

        local_event_hash(
          title: title,
          start_at: start_at,
          end_at: end_at,
          all_day: false,
          color: color_for_local_title(title),
          category: category_for_local_title(title),
          intent: intent_for_local_title(title),
          schedule_profile: profile_for_local_title(title),
          reason: '同じ日付内の複数時間指定を読み取り、予定候補を作成しました。',
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes]
        )
      end

      return invalid_generated_event_time_range_response if events.any?(&:nil?)

      return nil unless events.length >= 2

      build_local_bundle_response(
        title: "予定まとめ（#{events.length}件）",
        assistant_message: "#{date.strftime('%-m/%-d')}の複数時間指定を読み取り、#{events.length}件の予定候補を作成しました。",
        reason: '同じ日付の中に複数の時間帯が含まれていたため、別々の予定候補にしました。',
        events: events,
        provider: 'rails-local-same-day-multi-time-v1'
      )
    end

    def same_date_time_segments(text)
      normalized = normalize_japanese(text)
      ranges = collect_same_date_time_ranges(normalized)
      return [] if ranges.length < 2

      ranges.each_with_index.map do |range, index|
        next_range = ranges[index + 1]
        tail = normalized[range[:end_index]...(next_range ? next_range[:start_index] : normalized.length)].to_s
        activity_title = same_date_activity_title(range[:raw], tail)
        descriptor_text = [range[:raw], tail, activity_title].compact.join(' ')

        {
          start_minute: range[:start_minute],
          end_minute: range[:end_minute],
          duration_minutes: range[:duration_minutes],
          activity_title: activity_title,
          descriptor_text: descriptor_text
        }
      end
    end

    def collect_same_date_time_ranges(text)
      clock_scan = explicit_clock_scan(text)
      normalized = clock_scan[:source]
      ranges = explicit_time_range_matches(normalized, scan: clock_scan).filter_map do |range|
        duration_minutes = range[:end_minute] - range[:start_minute]
        next unless duration_minutes.positive?

        {
          raw: range[:raw],
          start_index: range[:start_index],
          end_index: range[:end_index],
          start_minute: range[:start_minute],
          end_minute: range[:end_minute],
          duration_minutes: duration_minutes,
          priority: 0
        }
      end

      clock_scan[:tokens].select { |token| token[:valid] }.each do |token|
        tail = normalized[token[:end_index]...].to_s
        duration_match = tail.match(
          /\A[ \t]*(?:から|〜|~|-)[ \t]*(?<duration_value>\d{1,3}(?:\.\d+)?)[ \t]*(?<duration_unit>時間|分)?(?![\d:：時じ])/
        )
        next unless duration_match

        duration_minutes = duration_value_to_minutes(
          duration_match[:duration_value],
          duration_match[:duration_unit]
        )
        next if duration_minutes.blank? || duration_minutes <= 0

        end_index = token[:end_index] + duration_match.end(0)
        ranges << {
          raw: normalized[token[:start_index]...end_index],
          start_index: token[:start_index],
          end_index: end_index,
          start_minute: token[:hour] * 60 + token[:minute],
          duration_minutes: [[duration_minutes, 5].max, 480].min,
          priority: 1
        }
      end

      selected = []
      ranges.sort_by { |range| [range[:start_index], range[:priority], -range[:end_index]] }.each do |range|
        next if selected.any? { |existing| same_date_range_overlap?(existing, range) }

        selected << range
      end

      selected.sort_by { |range| range[:start_index] }
    end

    def same_date_range_overlap?(left, right)
      left[:start_index] < right[:end_index] && right[:start_index] < left[:end_index]
    end

    def same_date_activity_title(raw_range, tail)
      title = normalize_japanese(tail)
      title = title.gsub(/^\s*(の|に|は|で|を|と|、|。)+/, '')
      title = title.gsub(/\s*(と|、|。|;|；)\s*$/, '')
      title = clean_activity_title(title)
      title = title.gsub(/^\s*(の|に|は|で|を|と)+/, '')
      title = title.gsub(/\s*(と|、|。)\s*$/, '')
      title = title.strip

      if title.blank? || title == '予定' || request_phrase_only?(title) || title.length > 18
        title = local_title_from_text("#{raw_range} #{tail}")
      end

      title
    end

    def local_schedule_syntax_clarification_response(text)
      return nil unless context_value(:scope).to_s == 'home'

      delimiter_scan = schedule_syntax_delimiter_scan(text)
      return nil unless delimiter_scan[:error]
      return nil unless schedule_like_syntax_input?(text, delimiter_scan: delimiter_scan)

      provider = 'rails-local-schedule-syntax-clarification-v1'
      policy_run = local_policy_run(
        provider,
        { delimiter_error: delimiter_scan.dig(:error, :kind) }
      )
      policy_run[:prompt_snapshot] = {
        redacted: true,
        scope: context_value(:scope)
      }

      {
        assistant_message: '括弧または引用符の対応を確認できませんでした。開始記号と終了記号を対応させて、予定をもう一度入力してください。候補はまだ作成していません。',
        recommendations: [],
        provider: provider,
        policy_run: policy_run,
        tool_invocations: []
      }
    end

    def schedule_syntax_delimiter_scan(text)
      source = text.to_s
      return scan_protected_text_delimiters(source) unless source == @user_message

      @schedule_syntax_delimiter_scan ||= scan_protected_text_delimiters(source)
    end

    def schedule_like_syntax_input?(text, delimiter_scan: nil)
      normalized = normalize_japanese(text)

      return true if explicit_clock_scan(normalized)[:tokens].any? ||
                     first_local_date_from_text(normalized).present? ||
                     explicit_date_syntax_present?(normalized) ||
                     target_weekdays(normalized).any? ||
                     normalized.match?(/\d+(?:\.\d+)?[ \t　]*(?:時間(?:[ \t　]*半|[ \t　]*\d+[ \t　]*分)?|分)/)

      delimiter_scan ||= scan_protected_text_delimiters(text)
      safe_boundaries = schedule_syntax_safe_boundaries(
        text,
        delimiter_scan: delimiter_scan
      )
      return true if schedule_action_syntax_input?(
        text,
        delimiter_scan: delimiter_scan,
        safe_boundaries: safe_boundaries
      )
      return true if schedule_activity_clause_syntax_input?(
        text,
        safe_boundaries: safe_boundaries
      )

      schedule_keyword_in_delimiter_error_clause?(
        text,
        delimiter_scan,
        safe_boundaries: safe_boundaries
      )
    end

    def schedule_keyword_in_delimiter_error_clause?(text, delimiter_scan, safe_boundaries:)
      delimiter_error = delimiter_scan[:error]
      return false unless delimiter_error

      source = text.to_s
      error_index = delimiter_error[:index].to_i
      clause_range = schedule_syntax_clause_range_for_index(
        source,
        error_index,
        safe_boundaries
      )
      clause = normalize_japanese(source[clause_range])
      return false if schedule_syntax_explanatory_clause?(clause)

      clause.match?(
        /予定|日程|スケジュール|カレンダー|イベント|会議|ミーティング|打ち合わせ|打合せ/
      )
    end

    def schedule_syntax_activity_subject?(subject)
      normalized = normalize_japanese(subject)
      normalized = normalized.sub(
        /[ 	　]*(?:です|でした|だ|だった|である|になります|になりました)\z/,
        ''
      )
      stripped = strip_request_action_suffix(normalized)
      explicit_request_shape = stripped != normalized
      normalized = stripped
      stripped = normalized.sub(
        /[ 	　]*(?:(?:を)?(?:したい|やりたい|入れたい|予約したい)|(?:に|へ)?行きたい|を取りたい)\z/,
        ''
      )
      explicit_request_shape ||= stripped != normalized
      normalized = stripped
      stripped = normalized.sub(/[ 	　]*の(?:時間|予定)\z/, '')
      explicit_request_shape ||= stripped != normalized
      normalized = stripped
      normalized = normalized.sub(/[ 	　]*(?:を|に|は|で|と|の)\z/, '').strip
      return false if normalized.match?(/を(?:レビュー|確認)\z/)

      compacted = normalized.gsub(/[ 	　]+/, '')
      return true if compacted.match?(
        /(?:#{SCHEDULE_SYNTAX_ACTIVITY_PATTERN.source})[A-Za-z0-9._-]*\z/x
      )
      return true if explicit_request_shape && compacted.match?(/\A(?:資料|メモ|確認)\z/)

      !compacted.match?(/[をのにはでとが]/) &&
        compacted.match?(/\A[\p{L}\p{N}._-]+(?:確認|レビュー)[A-Za-z0-9._-]*\z/)
    end

    def schedule_activity_clause_syntax_input?(text, safe_boundaries:)
      source = text.to_s
      clause_start_byte_index = 0

      safe_boundaries.each do |boundary|
        clause_end_byte_index = boundary[:byte_index]
        clause = source.byteslice(
          clause_start_byte_index,
          clause_end_byte_index - clause_start_byte_index
        ).to_s
        return true if schedule_syntax_activity_clause?(clause)

        clause_start_byte_index = boundary[:end_byte_index]
      end

      trailing_clause = source.byteslice(
        clause_start_byte_index,
        source.bytesize - clause_start_byte_index
      ).to_s
      schedule_syntax_activity_clause?(trailing_clause)
    end

    def schedule_syntax_activity_clause?(clause)
      subject = clause.to_s.gsub(/[「」『』“”‘’"'（）()\[\]［］【】]/, '')
      subject = subject.strip
      return false if schedule_syntax_explanatory_clause?(subject)

      schedule_syntax_activity_subject?(subject) ||
        schedule_syntax_qualified_activity_clause?(subject) ||
        schedule_syntax_short_activity_clause?(subject) ||
        focus_work_request?(subject) ||
        schedule_syntax_recurrence_clause?(subject) ||
        schedule_syntax_summary_clause?(subject) ||
        schedule_syntax_organization_clause?(subject) ||
        schedule_syntax_open_slot_clause?(subject) ||
        schedule_syntax_reminder_clause?(subject) ||
        schedule_syntax_between_activity_clause?(subject)
    end

    def schedule_syntax_qualified_activity_clause?(subject)
      return false if schedule_syntax_explanatory_clause?(subject)

      compacted = normalize_japanese(subject).gsub(/[ 	　]+/, '')
      compacted.match?(
        /\A(?:#{SCHEDULE_SYNTAX_ACTIVITY_PATTERN.source})[\p{L}\p{N}._-]+\z/x
      )
    end

    def schedule_syntax_short_activity_clause?(subject)
      normalized = normalize_japanese(subject)
      return false if normalized.length > 96
      return false if schedule_syntax_explanatory_clause?(normalized)
      return false if short_activity_request_excluded?(normalized)

      short_activity_title_from_text(normalized).present?
    end

    def schedule_syntax_summary_clause?(subject)
      normalized = normalize_japanese(subject)
      return false unless normalized.match?(/予定|スケジュール|カレンダー|忙しい日|空き時間/)

      schedule_summary_request?(normalized)
    end

    def schedule_syntax_organization_clause?(subject)
      normalized = normalize_japanese(subject)
      return false unless normalized.match?(
        /予定|スケジュール|整理したい|見直したい|棚卸ししたい/
      )

      schedule_organization_request?(normalized)
    end

    def schedule_syntax_explanatory_clause?(subject)
      normalized = normalize_japanese(subject)
                   .gsub(/[「」『』“”‘’"'（）()\[\]［］【】]/, '')
                   .strip
      return true if schedule_syntax_resource_operation_clause?(normalized)
      return false if schedule_syntax_existing_short_activity_task?(normalized)
      return false if normalized.match?(
        /\A(?:予定|予約|日程|スケジュール|カレンダー|イベント|空き時間|忙しい日)(?:を|は)(?:教えて|見せて|確認(?:して|する)?|まとめて|整理して)/
      )
      return true if schedule_syntax_metalinguistic_clause?(normalized)
      return true if normalized.match?(/とは無関係/)
      return true if normalized.match?(/とは(?:何|どんな|どういう|どのような)/)
      return true if normalized.match?(/って(?:何|どういう意味|どういうこと|どんなもの|どのようなもの)/)
      return true if normalized.match?(
        /(?:について|を)(?:
          知りたい(?:です)? |
          (?:教えて|説明して|解説して|調べて|検索して|見せて|探して|紹介して|おすすめして|評価して|比較して)
          (?:ほしい|ください|下さい)? |
          (?:注文|購入)したい |
          買おうと思う |
          買いたい
        )\z/x
      )
      return true if normalized.match?(
        /(?:の|という)(?:
          意味|仕組み|歴史|記事|感想|口コミ|写真|手順|方法|内容|議事録|
          言葉|単語|表現|話|設備|書き方|読み方|型番|使い方|住所|定義|
          場所|例|英訳|おすすめ|お勧め|オススメ|評価|評判|価格|値段|費用|
          料金|種類|お店|コツ|機能|情報|詳細|概要|やり方|仕方|アクセス|
          連絡先|営業時間|ニュース|画像|動画|内訳|明細|書式|テンプレート|
          フォーマット|サンプル|請求|サイズ|素材|仕様|url|比較|設定|地図|行き方
        )/x
      )
      return true if normalized.match?(
        /(?:番号|仕組み|意味|歴史|記事|感想|口コミ|写真|手順|方法|内容|議事録|帳|機|服|靴|館|室|欄|語|メニュー|名)(?:です|でした|だ|である)?\z/
      )
      return true if normalized.match?(
        /(?:番号|記事|感想(?:文)?|口コミ|写真|手順|方法|内容|議事録|帳|機|服|靴|館|室|欄|語|メニュー|名)(?:を|の|に|へ|は|で|とは|について)/
      )
      return true if normalized.match?(/旅行記(?:\z|を|の|に|へ|は|で|とは|について)/)
      normalized.match?(
        /を(?:見た|見て|見せて|読む|読んだ|読んで|終えた|書いた|整理した|説明(?:してください|して)?|英訳(?:してください|して)?|レビュー(?:してください|して|した)?|確認(?:してください|して|した)?|検索(?:して)?|調べ(?:て|た))(?:ください|下さい)?\z/
      )
    end

    def schedule_syntax_resource_operation_clause?(subject)
      normalized = normalize_japanese(subject)
                   .gsub(/[「」『』“”‘’"'（）()\[\]［］【】]/, '')
                   .strip

      normalized.match?(
        /(?:資料|ファイル|ページ|サイト|アプリ|画像|動画|文書|ドキュメント|
          フォルダ|リンク|url|画面|データ|帳|欄|pdf|csv|メール|メモ|会議録|議事録)
          (?:を|は)?
          (?:
            開(?:いて(?:ほしい|ください|下さい)?|く|きたい|けて(?:ほしい|ください|下さい)?|ける) |
            (?:起動|表示|共有|削除|保存|ダウンロード|アップロード|コピー|
              閲覧|再生|クリック|添付|同期|インストール)
            (?:して(?:ほしい|ください|下さい)?|する|したい) |
            閉じ(?:て(?:ほしい|ください|下さい)?|る|たい) |
            送(?:って(?:ほしい|ください|下さい)?|る|りたい) |
            読み込(?:んで(?:ほしい|ください|下さい)?|む|みたい) |
            (?:download|upload|copy|save|open|close|share|click|install|sync|attach|play)
          )
          \z/ix
      )
    end

    def schedule_syntax_existing_short_activity_task?(subject)
      normalized = normalize_japanese(subject).strip
      return false if normalized.match?(
        /の(?:意味|仕組み|歴史|記事|感想|口コミ|写真|手順|方法|内容|議事録|設備|書き方|
          読み方|型番|使い方|住所|定義|場所|例|おすすめ|お勧め|オススメ|評価|評判|
          価格|値段|費用|料金|種類|お店|コツ|機能|情報|詳細|概要|やり方|仕方|
          アクセス|連絡先|営業時間|ニュース|画像|動画|内訳|明細|書式|テンプレート|
          フォーマット|サンプル|請求|サイズ|素材|仕様|url|比較|設定|地図|行き方)/
      )
      task_action = normalized.match(
        /(?:
          書(?:く|きたい|きます|いて(?:ください|下さい)?|こう) |
          読(?:む|みたい|みます|んで(?:ください|下さい)?|もう) |
          作(?:る|りたい|ります|って(?:ください|下さい)?|ろう) |
          (?:提出|編集|印刷|確認|整理|予約|準備|掃除|修理|更新)
          (?:する|したい|します|して(?:ください|下さい)?|しよう) |
          購入する |
          の時間
        )\z/x
      )
      return false unless task_action

      task_subject = normalized[0...task_action.begin(0)]
                               .sub(/[ \t　]*(?:を|に|へ|と)\z/, '')
                               .strip

      task_subject.match?(SCHEDULE_SYNTAX_ACTIVITY_PATTERN) &&
        short_activity_title_from_text(task_subject).present?
    end

    def schedule_syntax_metalinguistic_clause?(subject)
      normalized = normalize_japanese(subject).strip
      return true if normalized.match?(
        /(?:という(?:言葉|単語|表現|話|作品名|概念)(?:の意味)?|というのは(?:何|どういう意味)?|とは(?:何(?:か)?|どういう意味)|の意味)(?:です|でした|だ|である)?\z/
      )
      return false if normalized.match?(/\A(?:予定|スケジュール|カレンダー)(?:を|は|について)/)

      normalized.match?(/について(?:教えて|説明して|知りたい)(?:ください|下さい)?\z/)
    end

    def schedule_syntax_recurrence_clause?(subject)
      normalized = normalize_japanese(subject)
      recurrence_request?(normalized.gsub(/毎日新聞(?:社)?/, ''))
    end

    def schedule_syntax_reminder_clause?(subject)
      normalized = normalize_japanese(subject)
      return false unless reminder_request?(normalized)
      return true if normalized.match?(/リマインダー|remind/i)

      normalized.match?(
        /#{SCHEDULE_SYNTAX_ACTIVITY_PATTERN.source}|予定|日程|スケジュール|カレンダー|イベント/x
      )
    end

    def schedule_syntax_open_slot_clause?(subject)
      normalized = normalize_japanese(subject)
      return false if normalized.match?(/空き(?:という|の意味|について)/)

      open_slot_request?(normalized)
    end

    def schedule_syntax_between_activity_clause?(subject)
      normalize_japanese(subject).match?(
        /(?:#{SCHEDULE_SYNTAX_ACTIVITY_PATTERN.source}).*と.*(?:#{SCHEDULE_SYNTAX_ACTIVITY_PATTERN.source}).*の間(?:です|でした|だ|だった|である)?\z/x
      )
    end

    def schedule_syntax_safe_boundaries(text, delimiter_scan:)
      source = text.to_s
      characters = source.each_char.to_a
      protected_spans = non_overlapping_text_spans(
        delimiter_scan[:spans] + domain_like_text_spans(source) + abbreviation_like_text_spans(source)
      )
      protected_span_index = 0
      byte_index = 0
      boundaries = []

      characters.each_with_index do |character, index|
        current_byte_index = byte_index
        byte_index += character.bytesize

        while protected_spans[protected_span_index] && protected_spans[protected_span_index].end <= index
          protected_span_index += 1
        end
        next if protected_spans[protected_span_index]&.cover?(index)

        conjunction = if character == 'そ'
                        SCHEDULE_SYNTAX_MULTI_CHARACTER_BOUNDARIES.find do |literal|
                          source.byteslice(current_byte_index, literal.bytesize) == literal
                        end
                      end
        if conjunction
          boundaries << {
            character_index: index,
            end_character_index: index + conjunction.length,
            byte_index: current_byte_index,
            end_byte_index: current_byte_index + conjunction.bytesize
          }
          next
        elsif SCHEDULE_SYNTAX_PERIOD_BOUNDARY_CHARACTERS.include?(character)
          previous_character = index.positive? ? characters[index - 1] : nil
          next if previous_character&.match?(/\d/) || characters[index + 1]&.match?(/\d/)
        elsif !SCHEDULE_SYNTAX_CLAUSE_BOUNDARY_CHARACTERS.include?(character)
          next
        end
        if SCHEDULE_SYNTAX_COMMA_BOUNDARY_CHARACTERS.include?(character) &&
           schedule_syntax_metalinguistic_continuation?(source, byte_index)
          next
        end

        boundaries << {
          character_index: index,
          end_character_index: index + 1,
          byte_index: current_byte_index,
          end_byte_index: byte_index
        }
      end

      boundaries.sort_by { |boundary| boundary[:character_index] }
    end

    def schedule_syntax_metalinguistic_continuation?(source, start_byte_index)
      tail = source.byteslice(start_byte_index, 96).to_s
      normalize_japanese(tail).match?(
        /\A[ 	　]*(?:という(?:言葉|単語|表現|話|作品名|概念)|というのは|とは(?:何|どういう意味)|について|の意味)/
      )
    end

    def schedule_syntax_clause_range_for_index(source, index, safe_boundaries)
      following_position = safe_boundaries.bsearch_index do |boundary|
        boundary[:character_index] >= index
      end
      previous_boundary = if following_position
                            following_position.positive? ? safe_boundaries[following_position - 1] : nil
                          else
                            safe_boundaries.last
                          end
      following_boundary = following_position ? safe_boundaries[following_position] : nil

      clause_start_index = previous_boundary ? previous_boundary[:end_character_index] : 0
      clause_end_index = following_boundary ? following_boundary[:character_index] : source.length
      clause_start_index...clause_end_index
    end

    def schedule_action_syntax_input?(text, delimiter_scan: nil, safe_boundaries: nil)
      source = text.to_s
      return false unless source.match?(SCHEDULE_SYNTAX_SCOPE_INTENT_PATTERN)

      delimiter_scan ||= scan_protected_text_delimiters(source)
      safe_boundaries ||= schedule_syntax_safe_boundaries(
        source,
        delimiter_scan: delimiter_scan
      )

      personal_events = Array(context_value(:personal_events))
      explanatory_clauses = {}
      resource_operation_clauses = {}

      source.to_enum(:scan, SCHEDULE_SYNTAX_SCOPE_INTENT_PATTERN).any? do
        match = Regexp.last_match
        clause_range = schedule_syntax_clause_range_for_index(
          source,
          match.begin(0),
          safe_boundaries
        )
        explanatory_clause = explanatory_clauses.fetch(clause_range) do
          explanatory_clauses[clause_range] =
            schedule_syntax_explanatory_clause?(source[clause_range])
        end
        resource_operation_clause = resource_operation_clauses.fetch(clause_range) do
          resource_operation_clauses[clause_range] =
            schedule_syntax_resource_operation_clause?(source[clause_range])
        end

        following_position = safe_boundaries.bsearch_index do |boundary|
          boundary[:character_index] >= match.begin(0)
        end
        previous_boundary = if following_position
                              following_position.positive? ? safe_boundaries[following_position - 1] : nil
                            else
                              safe_boundaries.last
                            end
        subject_end_byte_index = match.byteoffset(0).first
        clause_start_byte_index = previous_boundary ? previous_boundary[:end_byte_index] : 0
        subject_start_byte_index = [subject_end_byte_index - 512, clause_start_byte_index].max
        while subject_start_byte_index < subject_end_byte_index &&
              (source.getbyte(subject_start_byte_index) & 0xC0) == 0x80
          subject_start_byte_index += 1
        end
        subject = source.byteslice(
          subject_start_byte_index,
          subject_end_byte_index - subject_start_byte_index
        ).to_s
        subject = subject.gsub(/[「」『』“”‘’"'（）()\[\]［］【】]/, '')
        subject = normalize_japanese(subject)
                  .sub(/[ \t　]*(?:を|に|は|で|と|の)[ \t　]*\z/, '')
                  .strip

        self_scoped_reservation = subject.blank? && match[0].match?(/\A予約(?:して|する)\z/)
        activity_subject = schedule_syntax_activity_subject?(subject)
        explicit_action_activity = activity_subject && match[0].match?(SCHEDULE_SYNTAX_ACTION_PATTERN)
        next false if resource_operation_clause
        next false if explanatory_clause && !self_scoped_reservation && !explicit_action_activity

        self_scoped_reservation ||
          (personal_events.any? && matched_existing_events(subject).any?) ||
          activity_subject
      end
    end

    def explicit_date_syntax_present?(text)
      normalized = normalize_japanese(text)

      normalized.to_enum(:scan, EXPLICIT_DATE_COMPONENT_PATTERN).any? do
        match = Regexp.last_match
        !date_syntax_match_embedded_in_numeric_title?(normalized, match)
      end
    end

    def explicit_date_label_before_match?(source, match)
      cursor = horizontal_space_start_byte_index(source, match.byteoffset(0).first)
      particle = EXPLICIT_DATE_LABEL_PARTICLES.find do |candidate|
        candidate_size = candidate.bytesize
        cursor >= candidate_size &&
          source.byteslice(cursor - candidate_size, candidate_size) == candidate
      end
      if particle
        cursor -= particle.bytesize
        cursor = horizontal_space_start_byte_index(source, cursor)
      end

      EXPLICIT_DATE_LABEL_LITERALS.any? do |candidate|
        candidate_size = candidate.bytesize
        cursor >= candidate_size &&
          source.byteslice(cursor - candidate_size, candidate_size) == candidate
      end
    end

    def date_syntax_match_embedded_in_numeric_title?(source, match)
      return false unless match[0].to_s.include?('.')
      return false if explicit_date_label_before_match?(source, match)

      start_byte_index = match.byteoffset(0).first
      preceding_character = utf8_character_before_byte_index(source, start_byte_index)
      return true if preceding_character&.match?(/[\p{L}\p{N}_]/)

      cursor = horizontal_space_start_byte_index(source, start_byte_index)
      %w[version ver v].any? do |label|
        label_start_byte_index = cursor - label.bytesize
        next false if label_start_byte_index.negative?
        candidate = source.byteslice(label_start_byte_index, label.bytesize)
        next false unless candidate&.valid_encoding? && candidate.casecmp?(label)

        boundary_character = utf8_character_before_byte_index(source, label_start_byte_index)
        boundary_character.nil? || !boundary_character.match?(/[A-Za-z0-9_]/)
      end
    end

    def utf8_character_before_byte_index(source, byte_index)
      return nil unless byte_index.positive?

      character_start_byte_index = byte_index - 1
      while character_start_byte_index.positive? &&
            (source.getbyte(character_start_byte_index) & 0xC0) == 0x80
        character_start_byte_index -= 1
      end
      source.byteslice(
        character_start_byte_index,
        byte_index - character_start_byte_index
      )
    end

    def horizontal_space_start_byte_index(source, byte_index)
      cursor = byte_index
      while cursor.positive?
        if [0x09, 0x20].include?(source.getbyte(cursor - 1))
          cursor -= 1
        else
          space = NFKC_HORIZONTAL_SPACE_LITERALS.find do |candidate|
            candidate_size = candidate.bytesize
            cursor >= candidate_size &&
              source.byteslice(cursor - candidate_size, candidate_size) == candidate
          end
          break unless space

          cursor -= space.bytesize
        end
      end
      cursor
    end

    def raw_horizontal_space_only?(value)
      !value.to_s.empty? && value.each_char.all? do |character|
        RAW_HORIZONTAL_SPACE_CHARACTERS.include?(character)
      end
    end

    def horizontal_space_end_byte_index(source, byte_index)
      cursor = byte_index
      while cursor < source.bytesize
        if [0x09, 0x20].include?(source.getbyte(cursor))
          cursor += 1
        else
          space = NFKC_HORIZONTAL_SPACE_LITERALS.find do |candidate|
            source.byteslice(cursor, candidate.bytesize) == candidate
          end
          break unless space

          cursor += space.bytesize
        end
      end
      cursor
    end


    def invalid_explicit_time_response(text)
      invalid_time = invalid_explicit_time_match(text)
      return nil unless invalid_time

      raw = invalid_time[:raw].to_s

      {
        assistant_message: "「#{raw}」は通常の開始時刻としては無効です。23:00などへ自動変換せず、確認が必要です。翌1:00の意味なら「翌日1時」または具体的な日付で入力し直してください。",
        recommendations: [],
        provider: 'rails-local-time-validation-v1',
        policy_run: local_policy_run('rails-local-time-validation-v1', { invalid_time: raw }),
        tool_invocations: []
      }
    end

    def invalid_explicit_date_response(text)
      invalid_date = invalid_explicit_date_match(text)
      return nil unless invalid_date

      raw = invalid_date[:raw].to_s

      {
        assistant_message: "「#{raw}」は存在しない日付です。別の日付へ自動補正せず、候補は作成しません。正しい日付を入力し直してください。",
        recommendations: [],
        provider: 'rails-local-date-validation-v1',
        policy_run: local_policy_run('rails-local-date-validation-v1', { invalid_date: raw }),
        tool_invocations: []
      }
    end

    def invalid_time_range_response(text)
      invalid_range = invalid_explicit_time_range_match(text)
      return nil unless invalid_range

      raw = invalid_range[:raw].to_s
      if invalid_range[:invalid_local_clock]
        return {
          assistant_message: "「#{raw}」には、このタイムゾーンで存在しないか一意に決められない時刻が含まれています。別の時刻を指定してください。候補はまだ作成していません。",
          recommendations: [],
          provider: 'rails-local-time-range-validation-v1',
          policy_run: local_policy_run('rails-local-time-range-validation-v1', { invalid_range: raw, invalid_local_clock: true }),
          tool_invocations: []
        }
      end
      if invalid_range[:unbound_overnight_cue]
        return {
          assistant_message: "「#{raw}」の翌日指定をどの時間帯へ適用するか確認できませんでした。各予定の日付と時刻を明示してください。候補はまだ作成していません。",
          recommendations: [],
          provider: 'rails-local-time-range-validation-v1',
          policy_run: local_policy_run('rails-local-time-range-validation-v1', { invalid_range: raw, unbound_overnight_cue: true }),
          tool_invocations: []
        }
      end

      {
        assistant_message: "「#{raw}」は終了時刻が開始時刻より前になっています。長時間予定や翌日またぎとして自動変換せず、確認が必要です。終了時刻または「翌日」を含めて入力し直してください。",
        recommendations: [],
        provider: 'rails-local-time-range-validation-v1',
        policy_run: local_policy_run('rails-local-time-range-validation-v1', { invalid_range: raw }),
        tool_invocations: []
      }
    end

    def invalid_duration_response(text)
      invalid_duration = invalid_duration_match(text)
      return nil unless invalid_duration

      {
        assistant_message: '所要時間が0分以下のため、予定候補は作成しません。15分、30分など正の時間で指定してください。',
        recommendations: [],
        provider: 'rails-local-duration-validation-v1',
        policy_run: local_policy_run('rails-local-duration-validation-v1', { invalid_duration: invalid_duration[:raw] }),
        tool_invocations: []
      }
    end

    def local_negative_reminder_response(text)
      normalized = normalize_japanese(text)
      return nil unless reminder_request?(normalized)

      invalid = negative_reminder_offset_match(normalized)
      return nil unless invalid

      reminder_clarification_response("#{invalid}は指定できません。10分前、30分前、1時間前など正の時間で指定してください。", 0)
    end

    def local_temporal_contradiction_response(text)
      normalized = normalize_japanese(text)
      return nil if event_mutation_or_reference_request?(normalized)

      if explicit_all_day_request?(normalized) && explicit_time_present?(normalized)
        raw_time = explicit_time_matches(normalized).first
        time_label = raw_time ? raw_time[:raw].to_s : '時刻'
        return {
          assistant_message: "「終日」と「#{time_label}から」が同時に指定されています。終日予定にしますか？ それとも#{time_label}開始にしますか？ どちらにしますか？",
          recommendations: [],
          provider: 'rails-local-contradiction-all-day-time-v1',
          policy_run: local_policy_run('rails-local-contradiction-all-day-time-v1'),
          tool_invocations: []
        }
      end

      if (mismatch = explicit_date_weekday_mismatch(normalized))
        return {
          assistant_message: "#{mismatch[:date_label]}は#{mismatch[:actual_weekday]}で、指定された#{mismatch[:requested_weekday]}ではありません。正しい日付か曜日を確認してください。",
          recommendations: [],
          provider: 'rails-local-contradiction-date-weekday-v1',
          policy_run: local_policy_run('rails-local-contradiction-date-weekday-v1', mismatch),
          tool_invocations: []
        }
      end

      if morning_night_conflict_request?(normalized)
        return {
          assistant_message: '「朝」と「夜」が同時に指定されています。朝と夜のどちらに入れるか、または2件に分けるかを指定してください。',
          recommendations: [],
          provider: 'rails-local-contradiction-morning-night-v1',
          policy_run: local_policy_run('rails-local-contradiction-morning-night-v1'),
          tool_invocations: []
        }
      end

      nil
    end

    def local_phase45_ambiguous_schedule_clarification_response(text)
      normalized = normalize_japanese(text)
      return nil if event_mutation_or_reference_request?(normalized)
      return nil if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return nil if recurrence_request?(normalized)

      if vague_open_slot_without_details?(normalized)
        return {
          assistant_message: '空き時間の条件が不足しています。何を、どれくらいの時間、どの時間帯に入れたいかを指定してください。',
          recommendations: [],
          provider: 'rails-local-phase45-ambiguous-open-slot-v1',
          policy_run: local_policy_run('rails-local-phase45-ambiguous-open-slot-v1'),
          tool_invocations: []
        }
      end

      if date_only_schedule_request?(normalized)
        return {
          assistant_message: '予定の内容と時間が不足しています。何を、何時ごろ、どれくらい入れますか？',
          recommendations: [],
          provider: 'rails-local-phase45-ambiguous-date-only-v1',
          policy_run: local_policy_run('rails-local-phase45-ambiguous-date-only-v1'),
          tool_invocations: []
        }
      end

      if date_person_only_schedule_request?(normalized)
        person = clean_activity_title(remove_date_time_phrases(normalized)).presence || '相手'
        return {
          assistant_message: "#{person}との予定として受け取りましたが、内容と時間が不足しています。打ち合わせ、電話などの内容と、何時ごろかを指定してください。",
          recommendations: [],
          provider: 'rails-local-phase45-ambiguous-person-date-v1',
          policy_run: local_policy_run('rails-local-phase45-ambiguous-person-date-v1'),
          tool_invocations: []
        }
      end

      nil
    end

    def local_weekend_period_response(text)
      normalized = normalize_japanese(text)
      return nil unless weekend_period_request?(normalized)
      return nil if event_mutation_or_reference_request?(normalized)

      title_source = remove_weekend_period_phrases(text)
      descriptor = local_period_event_descriptor(title_source, fallback_title: local_title_from_text(text), original_text: text)
      title = descriptor[:title]
      if insufficient_activity_title?(title) || title == '予定'
        return {
          assistant_message: '土日の予定内容を教えてください。例:「土日で旅行」「来週末に帰省」のように入力してください。',
          recommendations: [],
          provider: 'rails-local-weekend-period-clarification-v1',
          policy_run: local_policy_run('rails-local-weekend-period-clarification-v1'),
          tool_invocations: []
        }
      end

      start_date = weekend_start_date_for_text(normalized)
      return nil unless start_date

      inclusive_end = start_date + 1
      start_at = app_time_zone.local(start_date.year, start_date.month, start_date.day, 0, 0, 0)
      exclusive_end = start_date + 2
      end_at = app_time_zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day, 0, 0, 0)

      event = local_event_hash(
        title: title,
        start_at: start_at,
        end_at: end_at,
        all_day: true,
        color: color_for_period_descriptor(descriptor),
        category: category_for_period_descriptor(descriptor),
        intent: intent_for_period_descriptor(descriptor),
        schedule_profile: profile_for_period_descriptor(descriptor),
        reason: "#{start_date.strftime('%-m/%-d')}から#{inclusive_end.strftime('%-m/%-d')}までの週末期間予定として候補を作成しました。",
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes]
      )

      build_local_bundle_response(
        title: title,
        assistant_message: "#{start_date.strftime('%-m/%-d')}から#{inclusive_end.strftime('%-m/%-d')}までの#{title}として終日予定候補を作成しました。",
        reason: event['reason'],
        events: [event],
        provider: 'rails-local-weekend-period-v1'
      )
    end


    def local_travel_time_assist_response(text)
      normalized = normalize_japanese(text)
      return nil unless travel_time_assist_request?(normalized)

      date = first_local_date_from_text(text)
      request_timing = parse_local_schedule_timing(text, default_duration: 60)
      start_minute = request_timing[:start_minute]
      event_duration = request_timing[:duration_minutes]
      return nil unless date && start_minute

      travel_route = extract_travel_route(text)
      destination = clean_travel_place(travel_route[:destination].presence || extract_local_location(text))
      travel_minutes = travel_route[:travel_minutes]
      arrival_buffer_minutes = extract_arrival_buffer_minutes(text)

      if destination.blank?
        return {
          assistant_message: '移動時間を予定に入れるには目的地が必要です。例:「自宅から大阪駅まで30分、明日10時に会議」のように指定してください。',
          recommendations: [],
          provider: 'rails-local-travel-destination-clarification-v1',
          policy_run: local_policy_run('rails-local-travel-destination-clarification-v1'),
          tool_invocations: []
        }
      end

      title_source = remove_travel_assist_phrases(text, destination: destination, origin: travel_route[:origin])
      title_display_source = remove_travel_assist_phrases(
        remove_date_time_phrases(text),
        destination: destination,
        origin: travel_route[:origin]
      )
      descriptor = local_event_descriptor(title_display_source.presence || title_source.presence || text)
      title = travel_assist_main_title(title_display_source.presence || title_source, descriptor)
      return nil if insufficient_activity_title?(title) || title == '予定'

      # Phase 5-A: 移動時間の「30分」を本予定の所要時間として誤用しない。
      # 例: 「明日10時に大阪駅で会議、移動時間30分」は会議60分 + 移動30分。
      schedule_timing = parse_local_schedule_timing(
        title_source,
        default_duration: default_duration_minutes_for_title(title)
      )
      schedule_duration = schedule_timing[:duration_minutes]
      event_duration = schedule_duration.presence || default_duration_minutes_for_title(title)

      event_start = local_time_at_minute(date, start_minute)
      return invalid_generated_event_time_range_response unless event_start

      event_end = if request_timing[:end_minute]
                    local_time_at_minute(date, request_timing[:end_minute])
                  else
                    event_start + (event_duration.presence || default_duration_minutes_for_title(title)).minutes
                  end
      return invalid_generated_event_time_range_response unless event_end && event_end > event_start
      event_duration = ((event_end - event_start) / 60).round

      main_conflicts = conflicting_events(context_value(:personal_events), event_start, event_end)
      if main_conflicts.any?
        conflict_title = event_title(main_conflicts.first)
        return {
          assistant_message: "#{event_start.strftime('%H:%M')}-#{event_end.strftime('%H:%M')}は既存予定「#{conflict_title}」と重なります。移動時間を入れる前に、会議時刻を変更するか既存予定を調整してください。",
          recommendations: [],
          provider: 'rails-local-travel-main-conflict-v1',
          policy_run: local_policy_run('rails-local-travel-main-conflict-v1', { conflict_title: conflict_title }),
          tool_invocations: []
        }
      end

      main_event = local_event_hash(
        title: title,
        start_at: event_start,
        end_at: event_end,
        all_day: false,
        color: color_for_local_title(title),
        category: category_for_local_title(title),
        intent: intent_for_local_title(title),
        schedule_profile: profile_for_local_title(title),
        reason: travel_minutes.to_i.positive? ? '場所と移動時間を考慮して予定候補を作成しました。' : '場所付き予定として候補を作成しました。',
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: destination,
        buffer_minutes: arrival_buffer_minutes.presence || descriptor[:buffer_minutes]
      )
      main_event['description'] = travel_assist_main_description(destination: destination, arrival_buffer_minutes: arrival_buffer_minutes)
      main_event['travel_assist'] = {
        'destination' => destination,
        'origin' => travel_route[:origin],
        'travel_minutes' => travel_minutes,
        'arrival_buffer_minutes' => arrival_buffer_minutes,
        'phase' => '5a'
      }.compact

      unless travel_minutes.to_i.positive?
        return build_local_candidates_response(
          assistant_message: "#{event_start.strftime('%H:%M')}に#{destination}で#{title}ですね。移動時間も予定に入れますか？ 出発地、移動時間、何分前に着きたいかを指定してください。例:「自宅から#{destination}まで30分、15分前に到着」。",
          reason: '場所付き予定として候補を作成し、移動時間追加に必要な情報を確認しています。',
          events: [main_event],
          provider: 'rails-local-travel-assist-location-v1'
        )
      end

      travel_end = event_start - arrival_buffer_minutes.to_i.minutes
      travel_start = travel_end - travel_minutes.to_i.minutes
      if travel_start < context_now
        return {
          assistant_message: "移動予定の開始時刻 #{travel_start.strftime('%-m/%-d %H:%M')} が過去になります。移動時間または予定時刻を見直してください。",
          recommendations: [],
          provider: 'rails-local-travel-past-start-v1',
          policy_run: local_policy_run('rails-local-travel-past-start-v1', { travel_start_at: travel_start.iso8601 }),
          tool_invocations: []
        }
      end

      travel_conflicts = conflicting_events(context_value(:personal_events), travel_start, travel_end)
      if travel_conflicts.any?
        conflict_title = event_title(travel_conflicts.first)
        return {
          assistant_message: "移動時間を入れると #{travel_start.strftime('%H:%M')}-#{travel_end.strftime('%H:%M')} が既存予定「#{conflict_title}」と重なります。会議時刻を変更するか、移動予定を調整してください。",
          recommendations: [],
          provider: 'rails-local-travel-conflict-v1',
          policy_run: local_policy_run('rails-local-travel-conflict-v1', { conflict_title: conflict_title }),
          tool_invocations: []
        }
      end

      travel_event = travel_event_hash(
        origin: travel_route[:origin],
        destination: destination,
        start_at: travel_start,
        end_at: travel_end,
        travel_minutes: travel_minutes,
        arrival_buffer_minutes: arrival_buffer_minutes
      )

      build_local_bundle_response(
        title: "移動込み: #{title}",
        assistant_message: "#{destination}での#{title}に合わせて、移動予定と本予定の2件を候補にしました。#{travel_label(origin: travel_route[:origin], destination: destination)} #{travel_start.strftime('%H:%M')}-#{travel_end.strftime('%H:%M')}、#{title} #{event_start.strftime('%H:%M')}-#{event_end.strftime('%H:%M')}です。",
        reason: '明示された移動時間を使い、移動予定と本予定をまとめて作成しました。',
        events: [travel_event, main_event],
        provider: 'rails-local-travel-assist-bundle-v1'
      )
    end

    def local_same_date_multi_explicit_time_response(text, clauses: nil)
      normalized = normalize_japanese(text)
      return nil if event_mutation_or_reference_request?(normalized)

      clauses ||= schedule_event_clauses(text)
      return nil unless multi_intent_schedule_request?(normalized, clauses: clauses)
      clauses = clauses.reject { |clause| weekday_multi_trailing_control_clause?(clause) }

      shared_date = first_local_date_from_text(text)
      title_sources = multi_event_title_sources(text, clauses)
      parsed = clauses.each_with_index.map do |clause, index|
        parse_multi_explicit_event_clause(clause, shared_date, title_source: title_sources[index])
      end
      if shared_date.blank? && explicit_numbered_list_continuation_request?(normalized)
        continuation_date = inferred_date_for_time_only(parsed.find { |item| item[:start_minute] }&.fetch(:start_minute, nil))
        parsed.each { |item| item[:date] ||= continuation_date }
      end
      schedule_like = parsed.select do |item|
        item[:time_present] ||
          (item[:title].present? && item[:title] != '予定' && !insufficient_activity_title?(item[:title]))
      end
      return nil unless schedule_like.length >= 2

      timed_items = schedule_like.select { |item| item[:time_present] }
      if timed_items.length < 2 && timed_items.any? { |item| insufficient_activity_title?(item[:title]) || item[:title] == '予定' }
        return nil
      end

      incomplete = schedule_like.find { |item| item[:date].blank? || item[:start_minute].blank? || insufficient_activity_title?(item[:title]) || item[:title] == '予定' }
      if incomplete
        missing_title = incomplete[:title].presence || clean_activity_title(remove_date_time_phrases(incomplete[:clause])).presence || '予定'
        return {
          assistant_message: "#{missing_title}の時間が不足しています。何時に入れるかを指定してください。複数予定は、各予定に日付・時刻・内容を付けて入力してください。",
          recommendations: [],
          provider: 'rails-local-multi-explicit-clarification-v1',
          policy_run: local_policy_run('rails-local-multi-explicit-clarification-v1', { missing_clause: incomplete[:clause] }),
          tool_invocations: []
        }
      end

      events = schedule_like.map do |item|
        build_local_event_payload(
          title: item[:title],
          date: item[:date],
          text: item[:clause],
          start_minute: item[:start_minute],
          end_minute: item[:end_minute],
          duration_minutes: item[:duration_minutes],
          default_duration: item[:duration_minutes] || 60,
          contact_name: item[:contact_name],
          participant_names: item[:participant_names],
          location: item[:location],
          buffer_minutes: item[:buffer_minutes],
          all_day: false
        )
      end

      return invalid_generated_event_time_range_response if events.any?(&:nil?)

      return nil unless events.length >= 2

      build_local_candidates_response(
        assistant_message: "以下#{events.length}件の予定候補を作成しました。",
        reason: '同じ文の中に複数の予定指定があったため、別々の予定候補に分解しました。',
        events: events,
        provider: 'rails-local-multi-explicit-events-v1'
      )
    end

    def local_explicit_event_conflict_response(text, clauses: nil)
      normalized = normalize_japanese(text)
      return nil unless explicit_timed_schedule_add_request?(normalized, clauses: clauses)

      descriptor = local_event_descriptor(text)
      title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
      return nil if insufficient_activity_title?(title) || title == '予定'

      timing = parse_local_schedule_timing(
        text,
        default_duration: default_duration_minutes_for_title(title)
      )
      start_minute = timing[:start_minute]
      duration = timing[:duration_minutes]
      return nil unless start_minute && duration&.positive?

      date = first_local_date_from_text(text)
      return nil unless date

      start_at = local_time_at_minute(date, start_minute)
      return invalid_generated_event_time_range_response unless start_at

      end_at = if timing[:end_minute]
                 local_time_at_minute(date, timing[:end_minute])
               else
                 start_at + duration.minutes
               end
      return invalid_generated_event_time_range_response unless end_at && end_at > start_at
      conflicts = conflicting_events(context_value(:personal_events), start_at, end_at)
      return nil if conflicts.empty?

      conflict = conflicts.first
      conflict_title = event_title(conflict)
      conflict_message = "#{start_at.strftime('%H:%M')}-#{end_at.strftime('%H:%M')}は既存予定「#{conflict_title}」と重なります。"
      alternative = next_available_event_after_conflict(
        date: date,
        duration: duration,
        conflicts: conflicts,
        title: title,
        descriptor: descriptor
      )

      if alternative
        alt_start = parse_context_time(alternative['start_at'])
        alt_end = parse_context_time(alternative['end_at'])
        alternative['description'] = conflict_message
        build_local_candidates_response(
          assistant_message: "#{conflict_message}別候補として#{alt_start.strftime('%H:%M')}-#{alt_end.strftime('%H:%M')}はどうですか？",
          reason: "指定時刻が既存予定「#{conflict_title}」と重なるため、同じ日の空き時間を代替候補として出しました。",
          events: [alternative],
          provider: 'rails-local-explicit-conflict-alternative-v1'
        )
      else
        {
          assistant_message: "#{conflict_message}同じ日に代替候補を見つけられませんでした。別の時間を指定してください。",
          recommendations: [],
          provider: 'rails-local-explicit-conflict-no-slot-v1',
          policy_run: local_policy_run('rails-local-explicit-conflict-no-slot-v1', { conflict_count: conflicts.length }),
          tool_invocations: []
        }
      end
    end

    def past_explicit_datetime_response(text)
      start_at = explicit_start_datetime_from_text(text)
      return nil unless start_at && start_at < context_now

      {
        assistant_message: "#{start_at.strftime('%-m/%-d %H:%M')}はすでに過去です。未来の日時を指定してください。",
        recommendations: [],
        provider: 'rails-local-past-explicit-datetime-v1',
        policy_run: local_policy_run('rails-local-past-explicit-datetime-v1', { requested_start_at: start_at.iso8601 }),
        tool_invocations: []
      }
    end

    def local_between_existing_events_response(text)
      normalized = normalize_japanese(text)
      return nil unless between_existing_events_request?(normalized)

      {
        assistant_message: '予定と予定の間に入れる依頼として受け取りましたが、参照している予定を特定できませんでした。候補は作成しません。対象の予定名、または日時を指定してください。',
        recommendations: [],
        provider: 'rails-local-between-events-clarification-v1',
        policy_run: local_policy_run('rails-local-between-events-clarification-v1'),
        tool_invocations: []
      }
    end

    def local_ambiguous_schedule_clarification_response(text)
      normalized = normalize_japanese(text)
      return nil unless ambiguous_schedule_request?(normalized)

      {
        assistant_message: '予定候補を作るには情報が足りません。何を、いつ、どのくらい入れたいかを指定してください。例:「明日の午後に30分、休憩を入れて」。',
        recommendations: [],
        provider: 'rails-local-ambiguous-schedule-clarification-v1',
        policy_run: local_policy_run('rails-local-ambiguous-schedule-clarification-v1'),
        tool_invocations: []
      }
    end

    def local_generic_schedule_clarification_response(text)
      return nil unless generic_schedule_request?(text)

      {
        assistant_message: '予定の内容と時間が不足しています。何を、いつ、どれくらい入れたいかを指定してください。',
        recommendations: [],
        provider: 'rails-local-generic-schedule-clarification-v1',
        policy_run: local_policy_run('rails-local-generic-schedule-clarification-v1'),
        tool_invocations: []
      }
    end

    def local_numbered_list_clarification_response(text)
      normalized = normalize_japanese(text)
      return nil if event_mutation_or_reference_request?(normalized) || recurrence_request?(normalized)
      return nil if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return nil unless numbered_schedule_context?(normalized)

      details = invalid_numbered_list_sequence_details(text)
      return nil unless details

      item_number = details[:item_number]
      {
        assistant_message: "番号付き予定の#{item_number}番目の内容が不足しているか、番号の並びを確認できませんでした。各項目に予定内容と日時を指定してください。候補はまだ作成していません。",
        recommendations: [],
        provider: 'rails-local-numbered-list-clarification-v1',
        policy_run: local_policy_run('rails-local-numbered-list-clarification-v1', details),
        tool_invocations: []
      }
    end

    def local_short_activity_open_slot_response(text)
      normalized = normalize_japanese(text)
      return nil if short_activity_request_excluded?(normalized)

      title = short_activity_title_from_text(text)
      if title.blank?
        return short_activity_generic_clarification_response if short_activity_generic_request?(normalized)

        return nil
      end

      duration = 60
      event = nil
      [context_now.to_date, context_now.to_date + 1].each do |date|
        start_minute = first_available_start_minute_for_date(
          date: date,
          duration: duration,
          text: text,
          title: title
        )
        next unless start_minute

        start_at = app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
        end_at = start_at + duration.minutes
        event = local_event_hash(
          title: title,
          start_at: start_at,
          end_at: end_at,
          all_day: false,
          color: color_for_local_title(title),
          category: category_for_local_title(title),
          intent: intent_for_local_title(title),
          schedule_profile: profile_for_local_title(title),
          reason: '日付・時刻が未指定のため、既存予定と重ならない空き時間を候補にしました。'
        )
        break
      end

      unless event
        return {
          assistant_message: "#{title}の空き時間を探しましたが、今日と明日の9:00-18:00に空き枠を見つけられませんでした。日付や時間帯を指定してください。",
          recommendations: [],
          provider: 'rails-local-short-activity-no-slot-v1',
          policy_run: local_policy_run('rails-local-short-activity-no-slot-v1', { recommendation_count: 0, duration_minutes: duration }),
          tool_invocations: []
        }
      end

      build_local_candidates_response(
        assistant_message: '時間指定がないため、空いている時間の候補を作成しました。必要なら日付や時刻を指定して変更できます。',
        reason: '短い予定名を内容として扱い、直近の空き時間を候補にしました。',
        events: [event],
        provider: 'rails-local-short-activity-open-slot-v1'
      )
    end

    def short_activity_request_excluded?(text)
      normalized = normalize_japanese(text)
      return true if event_mutation_or_reference_request?(normalized)
      return true if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return true if focus_work_request?(normalized)
      return true if recurrence_request?(normalized)
      return true if weekend_period_request?(normalized)
      return true if first_local_date_from_text(normalized)
      return true if explicit_time_present?(normalized) || period_window_hint?(normalized)
      return true if explicit_duration_minutes(normalized).present? || explicit_all_day_request?(normalized)
      return true if normalized.match?(/空き|空いて|候補|いつ|都合|調整/)

      false
    end

    def short_activity_title_from_text(text)
      title = explicit_activity_title_from_user_text(text)
      title = clean_activity_title(title)
      return nil if title.blank? || title == '予定'
      return nil if title.length > 18 || request_phrase_only?(title)
      return nil if short_activity_person_only_title?(title)
      return nil unless known_activity_title?(title)

      title
    end

    def short_activity_person_only_title?(title)
      normalized = normalize_japanese(title)
      return true if normalized.match?(/\A[一-龥ぁ-んァ-ヶA-Za-z0-9_\-]{1,18}(?:さん|くん|君|ちゃん)\z/)

      known_contact_names.any? { |name| normalize_japanese(name) == normalized }
    end

    def short_activity_generic_request?(text)
      title = clean_activity_title(text)
      title.blank? || title == '予定' || request_phrase_only?(title)
    end

    def short_activity_generic_clarification_response
      {
        assistant_message: '予定の内容と時間が不足しています。何を、いつ、どれくらい入れますか？',
        recommendations: [],
        provider: 'rails-local-short-activity-generic-clarification-v1',
        policy_run: local_policy_run('rails-local-short-activity-generic-clarification-v1'),
        tool_invocations: []
      }
    end

    def past_datetime_response(text)
      normalized = normalize_japanese(text)
      return nil unless past_datetime_request?(normalized)

      {
        assistant_message: '過去の日時への予定追加として受け取りました。過去日時には候補を作成しません。必要なら未来の日時を指定してください。',
        recommendations: [],
        provider: 'rails-local-past-date-validation-v1',
        policy_run: local_policy_run('rails-local-past-date-validation-v1'),
        tool_invocations: []
      }
    end

    def local_schedule_summary_response(text)
      normalized = normalize_japanese(text)
      return nil unless schedule_summary_request?(normalized)

      period_label, range_start, range_end = schedule_summary_range(normalized)
      visible_events = personal_events_between_dates(range_start, range_end).sort_by do |event|
        event_time_for_sort(event) || app_time_zone.local(range_end.year, range_end.month, range_end.day, 23, 59, 0)
      end

      message = if normalized.match?(/忙しい|多い|混んで|詰ま/)
                  busy_days_message(period_label, visible_events, range_start, range_end)
                else
                  schedule_summary_message(period_label, visible_events, range_start, range_end, include_attention: normalized.match?(/注意|ポイント|気をつけ|確認/))
                end

      {
        assistant_message: message,
        recommendations: [],
        provider: 'rails-local-schedule-summary-v1',
        policy_run: local_policy_run('rails-local-schedule-summary-v1', {
          period: period_label,
          visible_event_count: visible_events.length,
          range_start: range_start.iso8601,
          range_end: range_end.iso8601
        }),
        tool_invocations: []
      }
    end

    def local_schedule_organization_response(text)
      normalized = normalize_japanese(text)
      return nil unless schedule_organization_request?(normalized)

      period_label, range_start, range_end = schedule_organization_range(normalized)
      visible_events = personal_events_between_dates(range_start, range_end)
      count_message = visible_events.any? ? "現在見えている#{period_label}の予定は#{visible_events.length}件です。" : "#{period_label}の予定整理として受け取りました。"

      {
        assistant_message: "#{count_message} 新しい予定候補は作らず、棚卸し・優先度付け・移動候補の整理として扱います。固定予定、締切が近い予定、動かせる予定の3つに分けて見直してください。移動したい予定名を指定すると、移動先候補を出します。",
        recommendations: [],
        provider: 'rails-local-schedule-organization-v1',
        policy_run: local_policy_run('rails-local-schedule-organization-v1', { period: period_label, visible_event_count: visible_events.length }),
        tool_invocations: []
      }
    end

    def local_focus_work_response(text)
      normalized = normalize_japanese(text)
      return nil unless focus_work_request?(normalized)

      timing = parse_local_schedule_timing(normalized, default_duration: 90)
      parsed_start_minute = timing[:start_minute]
      duration = timing[:duration_minutes] || 90
      title = focus_work_title_from_text(@user_message.presence || text)
      dates = candidate_dates_for_request(normalized)
      return nil if dates.empty?

      window_start, window_end = if parsed_start_minute
                                   [parsed_start_minute, parsed_start_minute + duration]
                                 else
                                   preferred_minute_window(normalized)
      end

      events = []
      resolved_durations = []
      dates.each do |date|
        minute = window_start
        while minute + duration <= window_end
          start_at = local_time_at_minute(date, minute)
          return invalid_generated_event_time_range_response unless start_at

          end_at = if timing[:end_minute] && minute == parsed_start_minute
                     local_time_at_minute(date, timing[:end_minute])
                   else
                     start_at + duration.minutes
                   end
          break unless end_at && end_at > start_at
          resolved_durations << ((end_at - start_at) / 60).round

          unless conflicts_with_events?(context_value(:personal_events), start_at, end_at)
            events << local_event_hash(
              title: title,
              start_at: start_at,
              end_at: end_at,
              all_day: false,
              color: color_for_local_title(title),
              category: category_for_local_title(title),
              intent: 'focus_work',
              schedule_profile: 'focus_work',
              reason: '会議や関係者調整ではなく、作業時間として候補を出しました。'
            )
            break if events.length >= 3
          end

          minute += parsed_start_minute ? duration : 30
        end
        break if events.length >= 3
      end

      if events.empty?
        metadata = { recommendation_count: 0 }
        unique_durations = resolved_durations.uniq
        metadata[:duration_minutes] = unique_durations.sole if unique_durations.one?
        return {
          assistant_message: '集中作業の時間として受け取りましたが、条件に合う空き枠を見つけられませんでした。曜日・時間帯・所要時間のどれかを指定してください。',
          recommendations: [],
          provider: 'rails-local-focus-work-v1',
          policy_run: local_policy_run('rails-local-focus-work-v1', metadata),
          tool_invocations: []
        }
      end

      event_durations = events.filter_map { |event| local_event_duration_minutes(event) }.uniq
      duration_phrase = if event_durations.one?
                          "#{event_durations.sole}分枠"
                        elsif timing[:end_minute]
                          end_day_label = timing[:end_minute] >= 24 * 60 ? '翌日' : ''
                          "#{minute_label(parsed_start_minute)}から#{end_day_label}#{minute_label(timing[:end_minute] % (24 * 60))}までの枠"
                        else
                          "#{duration}分枠"
                        end

      build_local_candidates_response(
        assistant_message: "#{title}の時間として、予定が重なりにくい#{duration_phrase}を#{events.length}件出しました。",
        reason: '作業・集中系の予定として扱い、会議・関係者調整には変換していません。',
        events: events,
        provider: 'rails-local-focus-work-v1'
      )
    end

    def local_existing_event_delete_erase_response(text)
      return nil unless existing_event_delete_request?(text)

      matches = matched_existing_events(text).first(6)
      action_label = '削除'

      if matches.empty?
        return {
          assistant_message: "#{action_label}指示として受け取りましたが、対象予定を特定できませんでした。予定名、日付、時刻をもう少し具体的に指定してください。",
          recommendations: [],
          provider: 'rails-local-existing-event-delete-guard-v2',
          policy_run: local_policy_run('rails-local-existing-event-delete-guard-v2', { guarded_action: action_label, matched_count: 0 }),
          tool_invocations: []
        }
      end

      if matches.length > 1
        rows = matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")
        return {
          assistant_message: "#{action_label}対象と思われる予定が複数あります。安全のため自動#{action_label}はしません。対象を特定できるように、日時やタイトルを追加してください。\n#{rows}",
          recommendations: [],
          provider: 'rails-local-existing-event-delete-guard-v2',
          policy_run: local_policy_run('rails-local-existing-event-delete-guard-v2', { guarded_action: action_label, matched_count: matches.length }),
          tool_invocations: []
        }
      end

      target = matches.first
      attrs = target.to_h
      source_event_id = attrs[:id] || attrs['id']
      return nil if source_event_id.blank?

      title = attrs[:title] || attrs['title'] || '予定'
      payload = {
        'event_action' => 'delete',
        'source_event_id' => source_event_id,
        'title' => title,
        'description' => "#{format_event_for_message(target)} を削除します。"
      }

      {
        assistant_message: "#{format_event_for_message(target)} を削除候補として用意しました。実行前に確認してください。",
        recommendations: [
          {
            'kind' => 'event_delete',
            'title' => "#{title}を削除",
            'description' => payload['description'],
            'reason' => '既存予定の削除は、ユーザー確認後だけ実行します。',
            'start_at' => attrs[:start_at] || attrs['start_at'],
            'end_at' => attrs[:end_at] || attrs['end_at'],
            'all_day' => attrs[:all_day] || attrs['all_day'],
            'source_event_id' => source_event_id,
            'payload' => payload
          }
        ],
        provider: 'rails-local-existing-event-delete-v1',
        policy_run: local_policy_run('rails-local-existing-event-delete-v1', { source_event_id: source_event_id }),
        tool_invocations: []
      }
    end

    def existing_event_delete_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/削除|消して|消す|消したい|消去|なくして|取り消して|キャンセルして|キャンセル/)
      return false if normalized.match?(/追加|入れて|登録|作って|作成|通知|リマインダー|変更|移動|ずらして/)

      true
    end

    def existing_event_title_query_from_text(text)
      source = normalize_japanese_preserve_case(remove_participant_phrases(remove_date_time_phrases(text)))
      source = source.gsub(/(?:を)?(?:削除|消して|消す|消したい|消去|なくして|取り消して|キャンセルして|キャンセル).*$/i, '')
      source = source.gsub(/(?:を)?(?:変更|移動|ずらして|リスケ|延期|前倒し).*$/i, '')
      source = source.gsub(/(?:の)?(?:\d+|[一二三四五六七八九十]+)\s*時間前に?(?:通知|リマインダー).*$/i, '')
      source = source.gsub(/(?:の)?(?:時間|間)前に?(?:通知|リマインダー).*$/i, '')
      source = source.gsub(/(?:の)?(?:\d+|[一二三四五六七八九十]+)\s*分前に?(?:通知|リマインダー).*$/i, '')
      source = source.gsub(/(?:の)?(?:前|まえ)に?(?:通知|リマインダー|知らせて|アラート).*$/i, '')
      source = source.gsub(/\s*(を|に|は|で|と|の)\s*$/, '')
      title = clean_activity_title(source)
      normalized_title = normalize_japanese(title)
      return nil if normalized_title.blank?
      return nil if normalized_title.match?(/\A(?:予定|削除|変更|通知|リマインダー|確認|チェック)\z/)

      normalized_title
    end

    def local_event_reminder_response(text)
      normalized = normalize_japanese(text)
      return nil unless reminder_request?(normalized)

      matches = matched_existing_events(text).first(6)
      return reminder_clarification_response('リマインダーを設定する予定を特定できませんでした。予定名または日時を指定してください。', matches.length) if matches.empty?
      return reminder_clarification_response("リマインダー候補が複数あります。どの予定か分かるように日時やタイトルを追加してください。\n#{matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")}", matches.length) if matches.length > 1
      return reminder_clarification_response('会議の何分前に通知しますか？ 例: 10分前、30分前、1時間前', matches.length) unless explicit_reminder_offset_present?(normalized)

      target = matches.first
      attrs = target.to_h
      start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])
      return reminder_clarification_response('対象予定の開始時刻を読み取れませんでした。予定を開いて確認してください。', 1) unless start_at

      minutes_before = reminder_minutes_before(normalized)
      all_day = ActiveModel::Type::Boolean.new.cast(attrs[:all_day] || attrs['all_day'])
      base_time = all_day ? app_time_zone.local(start_at.year, start_at.month, start_at.day, 9, 0, 0) : start_at
      remind_at = base_time - minutes_before.minutes
      event_title = attrs[:title] || attrs['title'] || '予定'

      payload = {
        'event_action' => 'reminder',
        'source_event_id' => attrs[:id] || attrs['id'],
        'minutes_before' => minutes_before,
        'remind_at' => remind_at.iso8601,
        'target_title' => event_title,
        'title' => "#{event_title}のリマインダー",
        'description' => "#{format_event_for_message(target)} の#{minutes_before}分前に通知します。"
      }

      {
        assistant_message: "#{format_event_for_message(target)} の#{minutes_before}分前にリマインダー候補を作成しました。実行前に確認してください。",
        recommendations: [
          {
            'kind' => 'event_reminder',
            'title' => payload['title'],
            'description' => payload['description'],
            'reason' => '対象予定を特定し、指定されたタイミングのリマインダー候補を作成しました。',
            'start_at' => remind_at.iso8601,
            'end_at' => (remind_at + 1.minute).iso8601,
            'all_day' => false,
            'source_event_id' => payload['source_event_id'],
            'payload' => payload
          }
        ],
        provider: 'rails-local-event-reminder-v1',
        policy_run: local_policy_run('rails-local-event-reminder-v1', { source_event_id: payload['source_event_id'], minutes_before: minutes_before }),
        tool_invocations: []
      }
    end

    # 既存予定の変更・削除は、候補提示とユーザー確認後の実行に限定する。
    def local_existing_event_change_response(text)
      action =
        if text.match?(/削除|消して|キャンセル|取り消し/)
          'delete'
        elsif text.match?(/変更|移動|ずらして|リスケ|延期|前倒し/)
          'update'
        end
      return nil unless action

      matches = matched_existing_events(text).first(6)
      action_label = action == 'delete' ? '削除' : '変更'

      if matches.empty?
        return {
          assistant_message: "#{action_label}指示として受け取りましたが、対象予定を特定できませんでした。予定名、日付、時刻をもう少し具体的に指定してください。",
          recommendations: [],
          provider: 'rails-local-existing-event-guard-v6',
          policy_run: local_policy_run('rails-local-existing-event-guard-v6', { guarded_action: action_label, matched_count: 0 }),
          tool_invocations: []
        }
      end

      if matches.length > 1
        rows = matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")
        return {
          assistant_message: "#{action_label}対象と思われる予定が複数あります。安全のため自動#{action_label}はしません。対象を特定できるように、日時やタイトルを追加してください。\n#{rows}",
          recommendations: [],
          provider: 'rails-local-existing-event-guard-v6',
          policy_run: local_policy_run('rails-local-existing-event-guard-v6', { guarded_action: action_label, matched_count: matches.length }),
          tool_invocations: []
        }
      end

      target = matches.first
      attrs = target.to_h
      source_event_id = attrs[:id] || attrs['id']
      return nil if source_event_id.blank?

      if action == 'delete'
        payload = {
          'event_action' => 'delete',
          'source_event_id' => source_event_id,
          'title' => attrs[:title] || attrs['title'],
          'description' => "#{format_event_for_message(target)} を削除します。"
        }

        return {
          assistant_message: "#{format_event_for_message(target)} を削除候補として用意しました。実行前に確認してください。",
          recommendations: [
            {
              'kind' => 'event_delete',
              'title' => "#{attrs[:title] || attrs['title'] || '予定'}を削除",
              'description' => payload['description'],
              'reason' => '既存予定の削除は、ユーザー確認後だけ実行します。',
              'start_at' => attrs[:start_at] || attrs['start_at'],
              'end_at' => attrs[:end_at] || attrs['end_at'],
              'all_day' => attrs[:all_day] || attrs['all_day'],
              'source_event_id' => source_event_id,
              'payload' => payload
            }
          ],
          provider: 'rails-local-existing-event-delete-v1',
          policy_run: local_policy_run('rails-local-existing-event-delete-v1', { source_event_id: source_event_id }),
          tool_invocations: []
        }
      end

      update_payload = existing_event_update_payload(target, text)
      unless update_payload
        return {
          assistant_message: "#{format_event_for_message(target)} の変更指示として受け取りましたが、変更後の日時を特定できませんでした。例:「明日の会議を16時に変更」のように入力してください。",
          recommendations: [],
          provider: 'rails-local-existing-event-update-clarification-v1',
          policy_run: local_policy_run('rails-local-existing-event-update-clarification-v1', { source_event_id: source_event_id }),
          tool_invocations: []
        }
      end

      payload = {
        'event_action' => 'update',
        'source_event_id' => source_event_id,
        'title' => attrs[:title] || attrs['title'],
        'description' => "変更前: #{format_event_for_message(target)}\n変更後: #{format_datetime_range_for_message(update_payload['start_at'], update_payload['end_at'], update_payload['all_day'])} #{attrs[:title] || attrs['title']}",
        'updates' => update_payload
      }

      {
        assistant_message: "#{format_event_for_message(target)} の変更候補を作成しました。実行前に確認してください。",
        recommendations: [
          {
            'kind' => 'event_update',
            'title' => "#{attrs[:title] || attrs['title'] || '予定'}を変更",
            'description' => payload['description'],
            'reason' => '既存予定の変更は、ユーザー確認後だけ実行します。',
            'start_at' => update_payload['start_at'],
            'end_at' => update_payload['end_at'],
            'all_day' => update_payload['all_day'],
            'source_event_id' => source_event_id,
            'payload' => payload
          }
        ],
        provider: 'rails-local-existing-event-update-v1',
        policy_run: local_policy_run('rails-local-existing-event-update-v1', { source_event_id: source_event_id }),
        tool_invocations: []
      }
    end

    def local_open_slot_response(text)
      normalized = normalize_japanese(text)
      return nil unless open_slot_request?(normalized)

      descriptor = local_event_descriptor(text)
      duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title])).last
      duration ||= default_duration_minutes_for_title(descriptor[:activity_title])
      title = descriptor[:activity_title].presence || local_title_from_text(text)
      title = clean_activity_title(title)
      dates = candidate_dates_for_request(text)
      return nil if dates.empty?

      window_start, window_end = preferred_minute_window(text)
      candidates = []

      dates.each do |date|
        minute = window_start
        while minute + duration <= window_end
          start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
          end_at = start_at + duration.minutes

          unless conflicts_with_events?(context_value(:personal_events), start_at, end_at)
            candidates << local_event_hash(
              title: title,
              start_at: start_at,
              end_at: end_at,
              all_day: false,
              color: color_for_local_title(title),
              category: category_for_local_title(title),
              intent: intent_for_local_title(title),
              schedule_profile: profile_for_local_title(title),
              reason: '既存予定と重なりにくい空き時間として候補を出しました。',
              contact_name: descriptor[:contact_name],
              participant_names: descriptor[:participant_names],
              location: descriptor[:location],
              buffer_minutes: descriptor[:buffer_minutes]
            )
            break if candidates.length >= 3
          end

          minute += 30
        end
        break if candidates.length >= 3
      end

      if candidates.empty?
        return {
          assistant_message: "#{title}の空き時間を探しましたが、条件に合う#{duration}分枠を見つけられませんでした。曜日・時間帯・所要時間のどれかを変えてください。",
          recommendations: [],
          provider: 'rails-local-open-slot-v1',
          policy_run: local_policy_run('rails-local-open-slot-v1', { recommendation_count: 0, duration_minutes: duration }),
          tool_invocations: []
        }
      end

      build_local_candidates_response(
        assistant_message: "#{title}の空き時間として、#{duration}分枠を#{candidates.length}件出しました。",
        reason: '既存予定と重ならない空き枠を優先しました。',
        events: candidates,
        provider: 'rails-local-open-slot-v1'
      )
    end

    def local_availability_response(text)
      return nil unless text.match?(/空き|空いて|都合|(?<!打ち)合わせ|候補|いつ|できれば|無理なら/)

      descriptor = local_event_descriptor(text)
      return nil if descriptor[:participant_names].empty?

      duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title])).last
      duration ||= default_duration_minutes_for_title(descriptor[:activity_title])

      dates = candidate_dates_for_request(text)
      return nil if dates.empty?

      window_start, window_end = preferred_minute_window(text)
      buffer = descriptor[:buffer_minutes].to_i
      candidates = []

      dates.each do |date|
        minute = window_start
        while minute + duration <= window_end
          start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
          end_at = start_at + duration.minutes

          if free_for_all?(start_at, end_at, participant_names: descriptor[:participant_names], buffer_minutes: buffer)
            candidates << local_event_hash(
              title: descriptor[:title],
              start_at: start_at,
              end_at: end_at,
              all_day: false,
              color: color_for_local_title(descriptor[:title]),
              category: category_for_local_title(descriptor[:title]),
              intent: intent_for_local_title(descriptor[:title]),
              schedule_profile: profile_for_local_title(descriptor[:title]),
              reason: "#{descriptor[:participant_names].join('・')}と重なりにくい空き時間として候補を出しました。",
              contact_name: descriptor[:contact_name],
              participant_names: descriptor[:participant_names],
              location: descriptor[:location],
              buffer_minutes: buffer
            )
            break if candidates.length >= 3
          end

          minute += 30
        end
        break if candidates.length >= 3
      end

      return nil if candidates.empty?

      build_local_candidates_response(
        assistant_message: "#{descriptor[:participant_names].join('・')}との空き時間を見て、#{candidates.length}件の候補を出しました。",
        reason: '自分と相手の予定・相手の空き時間条件・前後バッファを見て候補を選びました。',
        events: candidates,
        provider: 'rails-local-peer-availability-v5'
      )
    end

    def local_multi_event_response(text, clauses: nil)
      clauses ||= schedule_event_clauses(text)
      items = parse_local_event_items(text, clauses: clauses)
      return nil unless items.length >= 2

      events = items.map do |item|
        build_local_event_payload(
          title: item[:title],
          date: item[:date],
          text: item[:text],
          start_minute: item[:start_minute],
          end_minute: item[:end_minute],
          duration_minutes: item[:duration_minutes],
          default_duration: item[:duration_minutes] || default_duration_minutes_for_title(item[:activity_title]),
          contact_name: item[:contact_name],
          participant_names: item[:participant_names],
          location: item[:location],
          buffer_minutes: item[:buffer_minutes],
          all_day: false
        )
      end

      return invalid_generated_event_time_range_response if events.any?(&:nil?)

      return nil unless events.length >= 2

      build_local_bundle_response(
        title: "予定まとめ（#{events.length}件）",
        assistant_message: "#{events.length}件の予定候補をまとめて作成しました。",
        reason: '複数の日付・予定名・相手名を読み取り、まとめて予定候補にしました。',
        events: events,
        provider: 'rails-local-multi-event-v5'
      )
    end

    def local_weekday_multi_event_response(text)
      normalized = normalize_japanese(text)
      return nil if recurrence_request?(normalized) || existing_event_delete_request?(normalized)
      return nil if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return nil if normalized.match?(/変更|移動|ずらして|リスケ|延期|前倒し|削除|消して|消す|キャンセル|取り消し/)
      if reminder_request?(normalized) && !weekday_multi_negative_notification_controls_only?(normalized)
        return nil
      end
      structural_request = mask_multi_event_structural_literals(normalized)
      input_weekdays = target_weekdays(structural_request).uniq
      return nil unless input_weekdays.length >= 2
      clauses = split_event_clauses(text)
      preserved_clauses = split_event_clauses(@user_message, preserve_case: true)
      preserved_clauses = clauses unless preserved_clauses.length == clauses.length
      ambiguous_anchor_clause = clauses.find { |clause| ambiguous_weekday_multi_anchor_clause?(clause) }
      if ambiguous_anchor_clause
        return {
          assistant_message: '複数曜日と複数時刻の対応が不明確です。各予定を句点や改行で分け、曜日・時刻・内容をそれぞれ指定してください。候補はまだ作成していません。',
          recommendations: [],
          provider: 'rails-local-weekday-multi-event-clarification-v1',
          policy_run: local_policy_run('rails-local-weekday-multi-event-clarification-v1', {
            clause_count: clauses.length,
            ambiguous_anchor_clause: ambiguous_anchor_clause
          }),
          tool_invocations: []
        }
      end

      explicit_weekday_request = normalized.match?(/予定候補|行います|行う|実施|入れて|追加|登録|作って|予定/)
      return nil unless explicit_weekday_request || shared_weekday_multi_event_request?(clauses)

      shared_duration = shared_weekday_multi_event_duration(normalized)

      first_weekday_clause_index = clauses.index do |clause|
        target_weekdays(mask_multi_event_structural_literals(clause)).any?
      end
      mixed_schedule_clauses = clauses.each_with_index.filter_map do |clause, index|
        next unless first_weekday_clause_index
        next unless target_weekdays(mask_multi_event_structural_literals(clause)).empty?
        next if weekday_multi_trailing_control_clause?(clause)
        next if index < first_weekday_clause_index && weekday_multi_leading_context_clause?(clause)

        clause if schedule_event_clause?(clause)
      end
      if mixed_schedule_clauses.any?
        mixed_titles = mixed_schedule_clauses.filter_map do |clause|
          descriptor = local_event_descriptor(clause)
          clean_activity_title(descriptor[:activity_title].presence || descriptor[:title]).presence
        end.first(3)
        mixed_title_label = mixed_titles.any? ? "（#{mixed_titles.join('・')}）" : ''

        return {
          assistant_message: "曜日指定の予定と別形式の予定#{mixed_title_label}が混在しています。各予定の日付または曜日と時刻を明示してください。候補はまだ作成していません。",
          recommendations: [],
          provider: 'rails-local-weekday-multi-event-clarification-v1',
          policy_run: local_policy_run('rails-local-weekday-multi-event-clarification-v1', {
            clause_count: clauses.length,
            mixed_schedule_clause_count: mixed_schedule_clauses.length
          }),
          tool_invocations: []
        }
      end

      framing_clause_index = weekday_multi_request_framing_clause_index(clauses)
      clause_results = clauses.each_with_index.map do |original_clause, index|
        structural_clause = mask_multi_event_structural_literals(original_clause)
        weekdays = target_weekdays(structural_clause).uniq
        next { status: :non_event, clause: original_clause } if weekdays.empty?

        preserved_title_clause = preserve_multi_event_literal_case(
          original_clause,
          preserved_clauses[index]
        )
        title_source = if index == framing_clause_index
                         strip_multi_event_terminal_framing(preserved_title_clause)
                       else
                         preserved_title_clause
                       end
        title_source = clean_weekday_multi_event_clause(title_source)
        title_descriptor = multi_event_title_descriptor(title_source)
        original_descriptor = local_event_descriptor(original_clause)
        descriptor = original_descriptor.merge(
          title: title_descriptor[:title],
          activity_title: title_descriptor[:activity_title]
        )
        title = clean_activity_title(title_descriptor[:activity_title].presence || title_descriptor[:title])
        timing = parse_local_schedule_timing(structural_clause, default_duration: nil)
        duration = timing[:duration_minutes].presence || shared_duration.presence || default_duration_minutes_for_title(title)
        date_anchor = first_local_date_from_text(structural_clause)
        dates_by_weekday = if date_anchor
                             weekdays
                               .map { |weekday| next_weekday_on_or_after(date_anchor, weekday) }
                               .uniq
                               .sort
                               .index_by(&:wday)
                           else
                             {}
                           end
        resolved_all_weekdays = weekdays.all? { |weekday| dates_by_weekday.key?(weekday) }

        {
          status: resolved_all_weekdays && !insufficient_activity_title?(title) && title != '予定' ? :complete : :incomplete,
          weekdays: weekdays,
          dates_by_weekday: dates_by_weekday,
          title: title,
          text: original_clause,
          start_minute: timing[:start_minute] || default_start_minute_for_text(structural_clause, title),
          end_minute: timing[:end_minute],
          duration_minutes: duration,
          descriptor: descriptor
        }
      end

      recognized_items = clause_results.reject { |item| item[:status] == :non_event }
      recognized_weekdays = recognized_items.flat_map { |item| Array(item[:weekdays]) }.uniq
      return nil unless recognized_weekdays.length >= 2

      incomplete_items = recognized_items.select { |item| item[:status] == :incomplete }
      if incomplete_items.any?
        missing_weekdays = incomplete_items.flat_map { |item| item[:weekdays] }.uniq.map { |weekday| WEEKDAY_LABELS.fetch(weekday) }.join('・')
        return {
          assistant_message: "#{missing_weekdays}の予定内容が不足しています。複数曜日の予定は、各曜日の内容を指定してください。候補はまだ作成していません。",
          recommendations: [],
          provider: 'rails-local-weekday-multi-event-clarification-v1',
          policy_run: local_policy_run('rails-local-weekday-multi-event-clarification-v1', {
            clause_count: recognized_items.length,
            incomplete_clause_count: incomplete_items.length
          }),
          tool_invocations: []
        }
      end

      items = recognized_items.select { |item| item[:status] == :complete }.flat_map do |item|
        item[:dates_by_weekday].values.sort.map do |date|
          item.merge(weekdays: [date.wday], date: date)
        end
      end
      return nil unless items.length >= 2
      return nil unless items.map { |item| item[:date].wday }.uniq.length >= 2

      events = items.map do |item|
        descriptor = item[:descriptor]
        build_local_event_payload(
          title: item[:title],
          date: item[:date],
          text: item[:text],
          start_minute: item[:start_minute],
          end_minute: item[:end_minute],
          duration_minutes: item[:duration_minutes],
          default_duration: item[:duration_minutes],
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          all_day: false
        )
      end

      build_local_candidates_response(
        assistant_message: "曜日ごとの指定を読み取り、#{events.length}件の予定候補に分けました。内容と日時を確認してから追加してください。",
        reason: '複数の曜日と予定内容を、それぞれ独立した予定候補として分解しました。',
        events: events,
        provider: 'rails-local-weekday-multi-event-v1'
      )
    end

    def weekday_multi_request_framing_clause_index(clauses)
      weekday_indexes = clauses.each_index.select do |index|
        target_weekdays(mask_multi_event_structural_literals(clauses[index])).any?
      end
      return nil if weekday_indexes.empty?

      unique_weekdays = weekday_indexes.flat_map do |index|
        target_weekdays(mask_multi_event_structural_literals(clauses[index]))
      end.uniq
      return nil unless unique_weekdays.length >= 2

      weekday_index = weekday_indexes.last
      trailing_clauses = clauses[(weekday_index + 1)..] || []
      return nil unless trailing_clauses.all? { |clause| weekday_multi_trailing_control_clause?(clause) }

      weekday_index if multi_event_terminal_framing(clauses[weekday_index])
    end

    def weekday_multi_leading_context_clause?(clause)
      normalized = normalize_japanese(clause).strip
      descriptor = local_event_descriptor(normalized)
      title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])

      schedule_event_framing_clause?(normalized, title) ||
        normalized.match?(
          /\A(?:eval-[a-z0-9-]+[ \t]+)?(?:(?:これは|以下は)[ \t]*)?(?:架空の議事録|参考メモ)です\z/i
        )
    end

    def weekday_multi_trailing_control_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip
      return false if explicit_time_present?(normalized)
      return false if first_local_date_from_text(normalized) || target_weekdays(normalized).any?

      fragments = normalized.split(/[、,;；]/).map(&:strip).reject(&:blank?)
      fragments.any? && fragments.all? { |fragment| weekday_multi_trailing_control_fragment?(fragment) }
    end

    def weekday_multi_trailing_control_fragment?(fragment)
      descriptor = local_event_descriptor(fragment)
      title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
      return true if schedule_event_framing_clause?(fragment, title)
      return true if fragment.match?(/\A予定候補(?:だけ|のみ)?(?:を)?(?:整理|確認)(?:して)?(?:ください)?\z/)
      return true if fragment.match?(
        /\A(?:を)?予定候補として(?:整理して(?:ください|下さい)?|整理する|まとめて(?:ください|下さい)?|まとめる)\z/
      )
      return true if fragment.match?(/\A(?:担当者|通知(?:先)?|担当者(?:や|と)通知(?:先)?)(?:は|を)?設定(?:しないで(?:ください)?|しない|しません|せず|不要|なし)\z/)

      fragment.match?(/\A(?:保存|登録|追加)(?:は|を)?(?:しないで(?:ください)?|しない|しません|せず|不要|なし)\z/)
    end

    def weekday_multi_negative_notification_controls_only?(text)
      notification_fragments = normalize_japanese(text)
                               .split(/[。\r\n、,;；]/)
                               .map(&:strip)
                               .reject(&:blank?)
                               .select { |fragment| reminder_request?(fragment) }
      notification_fragments.any? && notification_fragments.all? do |fragment|
        weekday_multi_trailing_control_fragment?(fragment)
      end
    end

    def strip_multi_event_terminal_framing(clause)
      framing = multi_event_terminal_framing(clause)
      return normalize_japanese_preserve_case(clause) unless framing

      framing[:source][0...framing[:begin_index]].rstrip
    end

    def multi_event_terminal_framing(clause)
      source = normalize_japanese_preserve_case(clause)
      match = source.match(MULTI_EVENT_TERMINAL_FRAMING_PATTERN)
      return nil unless match
      return nil if text_range_protected?(protected_text_spans(source), match.begin(0)...match.end(0))

      {
        source: source,
        begin_index: match.begin(0),
        end_index: match.end(0)
      }
    end

    def multi_event_request_framing_clause_index(clauses)
      event_indexes = clauses.each_index.select do |index|
        !weekday_multi_trailing_control_clause?(clauses[index]) && schedule_event_clause?(clauses[index])
      end
      return nil unless event_indexes.length >= 2
      return nil unless event_indexes.count { |index| explicit_time_present?(clauses[index]) } >= 2

      event_index = event_indexes.last
      trailing_clauses = clauses[(event_index + 1)..] || []
      return nil unless trailing_clauses.all? { |clause| weekday_multi_trailing_control_clause?(clause) }

      event_index if multi_event_terminal_framing(clauses[event_index])
    end

    def strip_multi_event_execution_action(clause)
      source = normalize_japanese_preserve_case(clause)
      match = source.match(MULTI_EVENT_EXECUTION_ACTION_PATTERN)
      return source unless match
      return source if text_range_protected?(protected_text_spans(source), match.begin(0)...match.end(0))

      source[0...match.begin(0)].rstrip
    end

    def multi_event_title_sources(text, event_clauses)
      preserved_event_clauses = split_event_clauses(@user_message, preserve_case: true)
        .select { |clause| schedule_event_clause?(clause) }
        .reject { |clause| weekday_multi_trailing_control_clause?(clause) }
      source_clauses = if preserved_event_clauses.length == event_clauses.length
                         preserved_event_clauses
                       else
                         event_clauses
                       end
      sources = event_clauses.each_with_index.map do |clause, index|
        preserve_multi_event_literal_case(clause, source_clauses[index])
      end
      return sources unless event_clauses.length >= 2
      return sources unless event_clauses.count { |clause| explicit_time_present?(clause) } >= 2

      all_clauses = split_event_clauses(text)
      framing_clause_index = multi_event_request_framing_clause_index(all_clauses)
      if framing_clause_index
        event_indexes = all_clauses.each_index.select do |index|
          !weekday_multi_trailing_control_clause?(all_clauses[index]) && schedule_event_clause?(all_clauses[index])
        end
        framing_event_index = event_indexes.index(framing_clause_index)
        if framing_event_index && framing_event_index < sources.length
          sources[framing_event_index] = strip_multi_event_terminal_framing(sources[framing_event_index])
        end
      end

      sources.map { |source| strip_multi_event_execution_action(source) }
    end

    def preserve_multi_event_literal_case(clause, preserved_clause)
      source = normalize_japanese(clause)
      preserved_source = normalize_japanese_preserve_case(preserved_clause)
      return source unless source.length == preserved_source.length

      multi_event_literal_spans(preserved_source).reverse_each do |range|
        source[range] = preserved_source[range]
      end
      source
    end

    def multi_event_title_descriptor(title_source)
      masked_source, literals = mask_multi_event_title_literals(title_source)
      descriptor = local_event_descriptor(masked_source)

      descriptor.merge(
        title: clean_multi_event_empty_containers(restore_multi_event_title_literals(descriptor[:title], literals)),
        activity_title: clean_multi_event_empty_containers(
          restore_multi_event_title_literals(descriptor[:activity_title], literals)
        )
      )
    end

    def mask_multi_event_title_literals(text)
      literals = []
      source = normalize_japanese_preserve_case(text)
      literal_ranges = multi_event_literal_spans(source)

      masked_source = +''
      cursor = 0
      literal_ranges.each do |range|
        masked_source << source[cursor...range.begin].to_s
        literal = source[range]
        token = "__CF_LITERAL_#{literals.length}__"
        literals << [token, literal]
        masked_source << token
        cursor = range.end
      end
      masked_source << source[cursor...source.length].to_s

      [masked_source, literals]
    end

    def restore_multi_event_title_literals(value, literals)
      literals.reduce(value.to_s) { |result, (token, literal)| result.gsub(token, literal) }
    end

    def multi_event_literal_spans(text)
      source = text.to_s
      protected_ranges = protected_text_spans(source).reject do |range|
        grouped_schedule_timing_span?(source, range)
      end
      ranges = protected_ranges + domain_like_text_spans(source) + abbreviation_like_text_spans(source)
      source.to_enum(:scan, /[A-Za-z][A-Za-z0-9_.-]*[ \t　]+[vV][ \t　]*\d+(?:\.\d+)+|[vV]\d+(?:\.\d+)+/).each do
        match = Regexp.last_match
        range = match.begin(0)...match.end(0)
        ranges << range unless text_range_protected?(ranges, range)
      end

      non_overlapping_text_spans(ranges)
    end

    def clean_multi_event_empty_containers(value)
      value.to_s
        .gsub(/\(\s*(?:所要(?:時間)?)?\s*\)|\[\s*(?:所要(?:時間)?)?\s*\]|【\s*(?:所要(?:時間)?)?\s*】/, '')
        .strip
    end

    def grouped_schedule_timing_span?(source, range)
      literal = source[range].to_s
      grouped_delimiters = { '(' => ')', '[' => ']', '【' => '】' }
      return false unless grouped_delimiters[literal[0]] == literal[-1]

      inner = literal[1...-1].to_s.strip
      return false if inner.blank?
      return true if inner.match?(
        /\A(?:所要(?:時間)?[ \t　]*)?(?:各[ \t　]*)?(?:\d+(?:\.\d+)?[ \t　]*時間(?:[ \t　]*半|[ \t　]*\d+[ \t　]*分)?|\d+[ \t　]*分)\z/
      )

      scan = explicit_clock_scan(inner)
      tokens = explicit_time_matches(scan[:source], scan: scan)
      return false if tokens.empty? || tokens.length > 2
      return false unless scan[:source][0...tokens.first[:start_index]].to_s.strip.empty?

      if tokens.one?
        return scan[:source][tokens.first[:end_index]...].to_s.strip.empty?
      end

      connector = scan[:source][tokens.first[:end_index]...tokens.last[:start_index]].to_s.strip
      suffix = scan[:source][tokens.last[:end_index]...].to_s.strip
      connector.match?(/\A(?:から|〜|~|-)(?:[ \t　]*(?:翌日|翌朝|翌))?\z/) && suffix.match?(/\A(?:まで)?\z/)
    end

    def domain_like_text_spans(text)
      ranges = []
      pattern = /(?:[A-Za-z0-9-]+#{NFKC_PERIOD_PATTERN.source})+(?:[^\s.．﹒․、。,;；]+#{NFKC_PERIOD_PATTERN.source})*[A-Za-z]{2,}/
      text.to_s.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        ranges << (match.begin(0)...match.end(0))
      end
      ranges
    end

    def abbreviation_like_text_spans(text)
      ranges = []
      pattern = /(?<![A-Za-z])(?:(?:No|Dr|Mr|Ms|Mrs|Prof|Sr|Jr|St|Mt)#{NFKC_PERIOD_PATTERN.source}|(?:[A-Za-z]#{NFKC_PERIOD_PATTERN.source}){2,})[^\s#{SCHEDULE_SYNTAX_CLAUSE_BOUNDARY_CHARACTER_CLASS}]*/i
      text.to_s.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        ranges << (match.begin(0)...match.end(0))
      end
      ranges
    end

    def non_overlapping_text_spans(ranges)
      ranges
        .sort_by { |range| [range.begin, -range.end] }
        .each_with_object([]) do |range, non_overlapping|
          non_overlapping << range if non_overlapping.empty? || range.begin >= non_overlapping.last.end
        end
    end

    def mask_multi_event_structural_literals(text)
      source = normalize_japanese_preserve_case(text)
      characters = source.each_char.to_a
      structural_spans = protected_text_spans(source).reject do |range|
        grouped_schedule_timing_span?(source, range)
      end
      structural_spans += domain_like_text_spans(source) + abbreviation_like_text_spans(source)
      non_overlapping_text_spans(structural_spans).each do |range|
        range.each { |index| characters[index] = ' ' }
      end
      characters.join
    end

    def weekday_multi_candidate_shape?(clauses)
      items = weekday_multi_candidate_items(clauses)

      weekday_multi_candidate_items_form_shape?(items)
    end

    def weekday_multi_candidate_items(clauses)
      framing_clause_index = weekday_multi_request_framing_clause_index(clauses)
      clauses.each_with_index.filter_map do |clause, index|
        structural_clause = mask_multi_event_structural_literals(clause)
        weekdays = target_weekdays(structural_clause).uniq
        next if weekdays.empty? || !explicit_time_present?(structural_clause)

        title_source = if index == framing_clause_index
                         strip_multi_event_terminal_framing(clause)
                       else
                         clause
                       end
        title_source = clean_weekday_multi_event_clause(title_source)
        descriptor = multi_event_title_descriptor(title_source)
        title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
        next if title.blank? || title == '予定' || insufficient_activity_title?(title) || request_phrase_only?(title)

        { index: index, weekdays: weekdays, title: title }
      end
    end

    def weekday_multi_candidate_items_form_shape?(items)
      items.length >= 2 &&
        items.flat_map { |item| item[:weekdays] }.uniq.length >= 2
    end

    def clean_weekday_multi_event_clause(clause)
      source = normalize_japanese_preserve_case(clause)
        .gsub(/(?:を)?\s*\d+(?:\.\d+)?\s*(?:時間\s*半|時間|分)\s*(?=(?:入れてください|入れて|入れる|追加してください|追加して|追加|登録してください|登録して|登録|作ってください|作って|作る))/, '')

      strip_multi_event_execution_action(source).strip
    end

    def shared_weekday_multi_event_duration(text)
      match = normalize_japanese(text).match(/各\s*\d+(?:\.\d+)?\s*(?:時間\s*半|時間|分)/)
      match ? explicit_duration_minutes(match[0]) : nil
    end

    def ambiguous_weekday_multi_anchor_clause?(clause)
      source = mask_multi_event_structural_literals(clause)
      target_weekdays(source).uniq.length >= 2 && independent_clock_group_count(source) >= 2
    end

    def shared_weekday_multi_event_request?(clauses)
      weekday_clauses = clauses.select do |clause|
        target_weekdays(mask_multi_event_structural_literals(clause)).any?
      end
      return false unless weekday_clauses.one?

      source = mask_multi_event_structural_literals(weekday_clauses.first)
      target_weekdays(source).uniq.length >= 2 && independent_clock_group_count(source) == 1
    end

    def independent_clock_group_count(text)
      clock_scan = explicit_clock_scan(text)
      tokens = explicit_time_matches(clock_scan[:source], scan: clock_scan)
      ranges = explicit_time_range_matches(clock_scan[:source], scan: clock_scan)
      used_token_indexes = {}
      non_overlapping_range_count = ranges.sort_by { |range| [range[:start_index], range[:end_index]] }.count do |range|
        token_indexes = [range[:start_token][:start_index], range[:end_token][:start_index]]
        next false if token_indexes.any? { |token_index| used_token_indexes[token_index] }

        token_indexes.each { |token_index| used_token_indexes[token_index] = true }
        true
      end

      [tokens.length - non_overlapping_range_count, 0].max
    end

    def local_single_explicit_event_response(text, require_explicit_time: false)
      return nil if normalize_japanese(text).match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)

      descriptor = local_event_descriptor(text)
      display_title = clean_activity_title(descriptor[:title])
      has_time_hint = explicit_time_present?(text) || period_window_hint?(text)
      all_day_requested = explicit_all_day_request?(text)
      return nil if require_explicit_time && !has_time_hint

      explicit_date = first_local_date_from_text(text)
      timing = parse_local_schedule_timing(
        text,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title])
      )

      if display_title == '予定' && !all_day_requested && explicit_time_present?(text)
        missing_details = []
        missing_details << '日付' unless explicit_date
        missing_details << '開始時刻' unless timing[:start_minute]
        missing_details << '所要時間または終了時刻' unless timing[:duration_explicit] || timing[:end_time_explicit]

        if missing_details.any?
          return {
            assistant_message: "予定候補を作るには#{missing_details.join('・')}が不足しています。例:「明日10時から30分」または「明日10時から11時」のように指定してください。",
            recommendations: [],
            provider: 'rails-local-generic-schedule-details-clarification-v1',
            policy_run: local_policy_run('rails-local-generic-schedule-details-clarification-v1', { missing_details: missing_details }),
            tool_invocations: []
          }
        end
      end

      start_minute = timing[:start_minute]
      duration = timing[:duration_minutes] || default_duration_minutes_for_title(descriptor[:activity_title])

      start_minute ||= default_start_minute_for_text(text, descriptor[:activity_title]) if has_time_hint && !all_day_requested
      date = explicit_date
      date ||= inferred_date_for_time_only(start_minute) if has_time_hint && !all_day_requested
      return nil unless date

      if !all_day_requested && !has_time_hint
        start_minute = first_available_start_minute_for_date(
          date: date,
          duration: duration,
          text: text,
          title: descriptor[:activity_title],
          participant_names: descriptor[:participant_names],
          buffer_minutes: descriptor[:buffer_minutes]
        )

        unless start_minute
          return {
            assistant_message: "#{display_title}の空き時間を探しましたが、条件に合う#{duration}分枠を見つけられませんでした。時間帯か所要時間を指定してください。",
            recommendations: [],
            provider: 'rails-local-single-no-time-no-slot-v1',
            policy_run: local_policy_run('rails-local-single-no-time-no-slot-v1', { recommendation_count: 0, duration_minutes: duration }),
            tool_invocations: []
          }
        end
      else
        start_minute ||= default_start_minute_for_text(text, descriptor[:activity_title]) unless all_day_requested
      end

      event = build_local_event_payload(
        title: display_title,
        date: date,
        text: text,
        start_minute: start_minute,
        end_minute: timing[:end_minute],
        duration_minutes: duration,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes],
        all_day: all_day_requested
      )
      return invalid_generated_event_time_range_response unless event

      duration = local_event_duration_minutes(event) || duration unless all_day_requested

      if (memory_response = local_saved_travel_route_candidates_response(
        event,
        descriptor,
        text,
        has_time_hint: has_time_hint,
        all_day_requested: all_day_requested
      ))
        return memory_response
      end

      assistant_message = if all_day_requested
                            "#{date.strftime('%-m/%-d')} 終日の#{display_title}として候補を作成しました。"
                          elsif !has_time_hint
                            '時間指定がないため、空いている時間の候補を作成しました。必要なら時間を指定して変更できます。'
                          elsif display_title == '予定'
                            "#{date.strftime('%-m/%-d')} #{minute_label(start_minute)}から#{duration}分の予定候補を作成しました。内容は未設定です。追加前に変更できます。"
                          elsif descriptor[:location].present?
                            "#{descriptor[:location]}での#{display_title}として予定候補を作成しました。必要なら「移動時間30分」のように追加入力すると移動予定も作成できます。"
                          else
                            "#{date.strftime('%-m/%-d')} #{minute_label(start_minute)}から#{duration}分の#{display_title}として候補を作成しました。"
                          end

      build_local_bundle_response(
        title: display_title,
        assistant_message: assistant_message,
        reason: '日付・開始時刻・所要時間を読み取り、指定に合わせた予定候補にしました。',
        events: [event],
        provider: 'rails-local-single-explicit-v5'
      )
    end

    def local_saved_travel_route_candidates_response(event, descriptor, text, has_time_hint:, all_day_requested:)
      return nil if all_day_requested || !has_time_hint
      return nil if travel_time_assist_request?(text)

      destination = descriptor[:location].presence || event['location']
      return nil if destination.blank?

      routes = matching_saved_travel_routes(destination).first(3)
      return nil if routes.empty?

      main_start = parse_context_time(event['start_at'])
      main_end = parse_context_time(event['end_at'])
      return invalid_generated_event_time_range_response unless main_start && main_end && main_end > main_start

      base_event = event.merge('all_day' => false)

      recommendations = [
        local_recommendation_from_event(base_event, reason: '指定された日時と場所に合わせた予定候補です。')
      ]

      routes.each do |route|
        buffer_minutes = saved_route_arrival_buffer_minutes(route, descriptor[:title])
        travel_minutes = route[:travel_minutes].to_i
        next unless travel_minutes.positive?

        arrival_at = main_start - buffer_minutes.minutes
        travel_start = arrival_at - travel_minutes.minutes
        next unless travel_start < arrival_at

        origin_name = route[:origin_name].to_s
        travel_event = local_event_hash(
          title: "移動: #{origin_name} → #{destination}",
          start_at: travel_start,
          end_at: arrival_at,
          all_day: false,
          color: '#06b6d4',
          category: 'travel',
          intent: 'travel',
          schedule_profile: 'travel',
          reason: '保存済みの移動時間メモリーから逆算しました。',
          location: destination
        )
        travel_event['description'] = "#{origin_name}から#{destination}へ移動"
        travel_event['travel_assist'] = {
          'origin' => origin_name,
          'destination' => destination,
          'travel_minutes' => travel_minutes,
          'arrival_buffer_minutes' => buffer_minutes,
          'source' => 'user_travel_route',
          'user_travel_route_id' => route[:id]
        }.compact

        main_event = base_event.merge(
          'travel_assist' => {
            'origin' => origin_name,
            'destination' => destination,
            'travel_minutes' => travel_minutes,
            'arrival_buffer_minutes' => buffer_minutes,
            'source' => 'user_travel_route',
            'user_travel_route_id' => route[:id]
          }.compact
        )

        recommendations << local_travel_bundle_recommendation(
          title: "#{base_event['title']}（#{origin_name}から移動込み）",
          events: [travel_event, main_event],
          reason: "#{origin_name}から#{destination}まで#{travel_minutes}分、#{buffer_minutes}分前到着として移動込み候補を作成しました。"
        )
      end

      return nil if recommendations.length <= 1

      {
        assistant_message: "#{destination}での#{base_event['title']}として、予定のみ候補と保存済みメモリーに基づく移動込み候補を作成しました。",
        recommendations: recommendations,
        provider: 'rails-local-saved-travel-memory-v1',
        policy_run: local_policy_run('rails-local-saved-travel-memory-v1', { recommendation_count: recommendations.length, saved_route_count: routes.length }),
        tool_invocations: []
      }
    end

    def local_recommendation_from_event(event, reason:)
      {
        'kind' => 'draft_event',
        'title' => clean_activity_title(event['title']),
        'description' => event['description'],
        'reason' => reason,
        'start_at' => event['start_at'],
        'end_at' => event['end_at'],
        'all_day' => event['all_day'],
        'payload' => event
      }
    end

    def local_travel_bundle_recommendation(title:, events:, reason:)
      first = events.first
      last = events.last
      payload = first.merge(
        'title' => title,
        'description' => 'AI秘書提案の移動込み予定候補',
        'events' => events,
        'all_day' => false
      )

      {
        'kind' => 'draft_event',
        'title' => title,
        'description' => payload['description'],
        'reason' => reason,
        'start_at' => first['start_at'],
        'end_at' => last['end_at'],
        'all_day' => false,
        'payload' => payload
      }
    end

    def matching_saved_travel_routes(destination)
      normalized_destination = normalize_place_name(destination)
      Array(context_value(:user_travel_routes)).filter_map do |route|
        attrs = route.respond_to?(:to_h) ? route.to_h.symbolize_keys : {}
        next unless ActiveModel::Type::Boolean.new.cast(attrs.fetch(:active, true))
        next unless saved_route_destination_matches?(attrs[:destination_name], normalized_destination)

        {
          id: attrs[:id],
          origin_name: attrs[:origin_name].to_s.strip,
          origin_kind: attrs[:origin_kind].to_s.strip.presence,
          destination_name: attrs[:destination_name].to_s.strip,
          travel_minutes: attrs[:travel_minutes].to_i,
          transport_mode: attrs[:transport_mode].to_s.strip.presence,
          arrival_buffer_minutes: attrs[:arrival_buffer_minutes]
        }
      end.select { |route| route[:origin_name].present? && route[:travel_minutes].positive? }
    end

    def saved_route_destination_matches?(route_destination, normalized_destination)
      normalized_route_destination = normalize_place_name(route_destination)
      return false if normalized_route_destination.blank? || normalized_destination.blank?

      normalized_route_destination == normalized_destination ||
        normalized_route_destination.include?(normalized_destination) ||
        normalized_destination.include?(normalized_route_destination)
    end

    def saved_route_arrival_buffer_minutes(route, title)
      explicit = route[:arrival_buffer_minutes]
      return bounded_minutes(explicit, min: 0, max: 180) if explicit.present?

      key = "arrival_buffer.#{arrival_buffer_preference_key_for_label(title)}"
      preference = ai_user_preference_value(key).presence || ai_user_preference_value('arrival_buffer.default')
      bounded_minutes(preference, min: 0, max: 180) || 0
    end

    def ai_user_preference_value(key)
      Array(context_value(:ai_user_preferences)).each do |preference|
        attrs = preference.respond_to?(:to_h) ? preference.to_h.symbolize_keys : {}
        return attrs[:value] if attrs[:key].to_s == key
      end
      nil
    end

    def normalize_place_name(value)
      normalize_japanese(value).gsub(/\s+/, '')
    end

    def local_date_range_response(text)
      range = local_period_date_range_from_text(text)
      return nil unless range

      start_date = range[:start_date]
      end_date = range[:end_date]
      return nil unless start_date && end_date

      end_date = Date.new(end_date.year + 1, end_date.month, end_date.day) if end_date < start_date
      descriptor = local_period_event_descriptor(range[:tail], fallback_title: local_title_from_text(text), original_text: text)

      start_at = app_time_zone.local(start_date.year, start_date.month, start_date.day, 0, 0, 0)
      exclusive_end = end_date + 1
      end_at = app_time_zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day, 0, 0, 0)

      event = local_event_hash(
        title: descriptor[:title],
        start_at: start_at,
        end_at: end_at,
        all_day: true,
        color: color_for_period_descriptor(descriptor),
        category: category_for_period_descriptor(descriptor),
        intent: intent_for_period_descriptor(descriptor),
        schedule_profile: profile_for_period_descriptor(descriptor),
        reason: "#{start_date.strftime('%-m/%-d')}から#{end_date.strftime('%-m/%-d')}までの期間予定として候補を作成しました。",
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes]
      )

      build_local_bundle_response(
        title: descriptor[:title],
        assistant_message: "#{start_date.strftime('%-m/%-d')}から#{end_date.strftime('%-m/%-d')}までの#{descriptor[:title]}として候補を作成しました。",
        reason: event['reason'],
        events: [event],
        provider: 'rails-local-date-range-v5'
      )
    end

    def local_recurrence_response(text)
      return nil unless text.match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)

      local_daily_recurrence_response(text) ||
        local_monthly_nth_weekday_response(text) ||
        local_monthly_day_response(text) ||
        local_weekly_or_biweekly_response(text)
    end

    def local_daily_recurrence_response(text)
      return nil unless text.match?(/毎日|毎朝|毎晩/)

      descriptor = local_event_descriptor(text, fallback_title: '日課')
      timing = parse_local_schedule_timing(
        text,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title])
      )
      start_minute = timing[:start_minute]
      duration = timing[:duration_minutes]
      start_minute ||= default_start_minute_for_text(text, descriptor[:activity_title])

explicit_first_date = first_local_date_from_text(text)
first_date = explicit_first_date || context_now.to_date

if explicit_first_date.nil? && start_minute
  candidate_start = app_time_zone.local(first_date.year, first_date.month, first_date.day, start_minute / 60, start_minute % 60, 0)
  first_date += 1 if candidate_start < context_now
end

events = 8.times.map do |i|
        build_local_event_payload(
          title: descriptor[:title],
          date: first_date + i,
          text: text,
          start_minute: start_minute,
          end_minute: timing[:end_minute],
          duration_minutes: duration,
          default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          all_day: false
        )
      end

      build_local_bundle_response(
        title: "#{descriptor[:title]}（毎日）",
        assistant_message: "毎日の#{descriptor[:title]}として、#{events.length}件分の繰り返し候補を1枚のカードにまとめました。追加すると各日に予定を作成します。",
        reason: '毎日の繰り返し予定として候補をまとめました。',
        events: events,
        provider: 'rails-local-daily-recurrence-v1',
        recurrence_kind: 'daily',
        recurrence_label: '毎日'
      )
    end

    def local_weekly_or_biweekly_response(text)
      return nil unless text.match?(/毎週|隔週/)

      weekdays = target_weekdays(text)
      return nil if weekdays.empty?

      interval = text.include?('隔週') ? 2 : 1
      now = context_now
      descriptor = local_event_descriptor(text, fallback_title: '定例')
      recurrence_content = recurrence_content_source(text)
      activity_title = recurrence_activity_title_from_text(text)
      participant_names = participant_names_from_text(recurrence_content)
      descriptor[:activity_title] = activity_title
      descriptor[:participant_names] = participant_names
      descriptor[:contact_name] = participant_names.first
      descriptor[:title] = compose_local_event_title(activity_title, participant_names)
      timing = parse_local_schedule_timing(
        text,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title])
      )
      start_minute = timing[:start_minute]
      duration = timing[:duration_minutes]
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      events = []
      weekdays.each do |weekday|
        first = next_weekday_on_or_after(now.to_date, weekday)
        first_start = app_time_zone.local(first.year, first.month, first.day, start_minute / 60, start_minute % 60, 0)
        first += interval * 7 if first_start <= now

        8.times do |i|
          date = first + (i * interval * 7)
          events << build_local_event_payload(
            title: descriptor[:title],
            date: date,
            text: text,
            start_minute: start_minute,
            end_minute: timing[:end_minute],
            duration_minutes: duration,
            default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
            contact_name: descriptor[:contact_name],
            participant_names: descriptor[:participant_names],
            location: descriptor[:location],
            buffer_minutes: descriptor[:buffer_minutes],
            all_day: false
          )
        end
      end

      return invalid_generated_event_time_range_response if events.any?(&:nil?)

      events = events.sort_by { |event| event['start_at'].to_s }.first(16)
      label = interval == 2 ? '隔週' : '毎週'
      weekday_label = weekdays.map { |weekday| WEEKDAY_LABELS.fetch(weekday) }.join('・')
      event_label = descriptor[:title] == '予定' ? '繰り返し予定' : descriptor[:title]
      unset_content_note = descriptor[:title] == '予定' ? '内容は未設定です。' : ''
      if timing[:end_minute]
        end_day_label = timing[:end_minute] >= 24 * 60 ? '翌日' : ''
        range_label = "#{minute_label(start_minute)}-#{end_day_label}#{minute_label(timing[:end_minute] % (24 * 60))}"
        recurrence_label = "#{label}#{weekday_label} #{range_label}"
        assistant_message = "#{label}#{weekday_label} #{range_label}の#{event_label}を#{events.length}件候補にしました。#{unset_content_note}"
        reason = "#{label}#{weekday_label} #{range_label}の繰り返し予定として候補をまとめました。"
      else
        duration_label = local_duration_label(duration)
        recurrence_label = "#{label}#{weekday_label} #{minute_label(start_minute)} / #{duration_label}"
        assistant_message = "#{label}#{weekday_label}#{minute_label(start_minute)}から#{duration_label}の#{event_label}を#{events.length}件候補にしました。#{unset_content_note}"
        reason = "#{label}#{weekday_label}#{minute_label(start_minute)}から#{duration_label}の繰り返し予定として候補をまとめました。"
      end
      build_local_bundle_response(
        title: "#{descriptor[:title]}（#{label}）",
        assistant_message: assistant_message,
        reason: reason,
        events: events,
        provider: 'rails-local-weekly-recurrence-v5',
        recurrence_kind: interval == 2 ? 'biweekly' : 'weekly',
        recurrence_label: recurrence_label
      )
    end

    def recurrence_activity_title_from_text(text)
      source = recurrence_content_source(text)
      source = remove_local_location_phrases(remove_participant_phrases(source))
      title = clean_activity_title(source)

      insufficient_activity_title?(title) ? '予定' : title
    end

    def recurrence_content_source(text)
      source = normalize_japanese_preserve_case(text)
      source = source.gsub(/(?:毎週|隔週)\s*[月火水木金土日](?:[・･、,\/／と]?\s*[月火水木金土日])*(?:曜日|曜)?/, '')
      source = source.gsub(/[・･]?\s*\d+(?:\.\d+)?\s*時間\s*半/, '')
      source = source.gsub(/[・･]?\s*\d+(?:\.\d+)?\s*時間/, '')
      source = source.gsub(/[・･]?\s*\d+\s*分/, '')
      remove_date_time_phrases(source)
    end

    def local_monthly_nth_weekday_response(text)
      match = text.match(/毎月第(?<ordinal>[1-5一二三四五])(?<weekday>[月火水木金土日])(?:曜日|曜)?/)
      return nil unless match

      ordinal = japanese_ordinal_to_i(match[:ordinal])
      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless ordinal && weekday

      descriptor = local_event_descriptor(text, fallback_title: '定例')
      timing = parse_local_schedule_timing(
        text,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title])
      )
      start_minute = timing[:start_minute]
      duration = timing[:duration_minutes]
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      dates = []
      year = context_now.year
      month = context_now.month
      12.times do
        date = nth_weekday_date(year, month, weekday, ordinal)
        dates << date if date && date >= context_now.to_date
        year, month = add_months(year, month, 1)
        break if dates.length >= 6
      end

      events = dates.map do |date|
        build_local_event_payload(
          title: descriptor[:title],
          date: date,
          text: text,
          start_minute: start_minute,
          end_minute: timing[:end_minute],
          duration_minutes: duration,
          default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          all_day: false
        )
      end

      build_local_bundle_response(
        title: "#{descriptor[:title]}（毎月第#{ordinal}#{match[:weekday]}曜）",
        assistant_message: "毎月第#{ordinal}#{match[:weekday]}曜の#{descriptor[:title]}として、#{events.length}件の予定候補を作成しました。",
        reason: '毎月第n曜日の繰り返し予定として候補をまとめました。',
        events: events,
        provider: 'rails-local-monthly-nth-weekday-v5'
      )
    end

    def local_monthly_day_response(text)
      match = text.match(/毎月(?<day>3[01]|[12]\d|0?[1-9])日/)
      return nil unless match

      day = match[:day].to_i
      descriptor = local_event_descriptor(text, fallback_title: '予定')
      timing = parse_local_schedule_timing(
        text,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title])
      )
      start_minute = timing[:start_minute]
      duration = timing[:duration_minutes]
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      dates = []
      year = context_now.year
      month = context_now.month
      12.times do
        begin
          date = Date.new(year, month, day)
          dates << date if date >= context_now.to_date
        rescue Date::Error
        end
        year, month = add_months(year, month, 1)
        break if dates.length >= 6
      end

      events = dates.map do |date|
        build_local_event_payload(
          title: descriptor[:title],
          date: date,
          text: text,
          start_minute: start_minute,
          end_minute: timing[:end_minute],
          duration_minutes: duration,
          default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          all_day: false
        )
      end

      build_local_bundle_response(
        title: "#{descriptor[:title]}（毎月#{day}日）",
        assistant_message: "毎月#{day}日の#{descriptor[:title]}として、#{events.length}件の予定候補を作成しました。",
        reason: '毎月指定日の繰り返し予定として候補をまとめました。',
        events: events,
        provider: 'rails-local-monthly-day-v5'
      )
    end

    def build_local_bundle_response(title:, assistant_message:, reason:, events:, provider:, recurrence_kind: nil, recurrence_label: nil)
      return invalid_generated_event_time_range_response unless events.all? { |event| positive_local_event_time_range?(event) }

      first = events.first
      display_title = clean_activity_title(title)
      payload = first.merge('events' => events)
      if recurrence_kind.present?
        payload['recurrence_kind'] = recurrence_kind
        payload['recurrence_label'] = recurrence_label if recurrence_label.present?
        payload['target_dates'] = events.map { |event| Time.iso8601(event['start_at']).to_date.iso8601 rescue nil }.compact.uniq
      end

      {
        assistant_message: assistant_message,
        recommendations: [
          {
            'kind' => 'draft_event',
            'title' => display_title,
            'description' => first['description'],
            'reason' => reason,
            'start_at' => first['start_at'],
            'end_at' => first['end_at'],
            'all_day' => first['all_day'],
            'payload' => payload
          }
        ],
        provider: provider,
        policy_run: local_policy_run(provider, { recommendation_count: 1, bundled_event_count: events.length }),
        tool_invocations: []
      }
    end

    def build_local_candidates_response(assistant_message:, reason:, events:, provider:)
      return invalid_generated_event_time_range_response unless events.all? { |event| positive_local_event_time_range?(event) }

      {
        assistant_message: assistant_message,
        recommendations: events.map do |event|
          {
            'kind' => 'draft_event',
            'title' => clean_activity_title(event['title']),
            'description' => event['description'],
            'reason' => reason,
            'start_at' => event['start_at'],
            'end_at' => event['end_at'],
            'all_day' => event['all_day'],
            'payload' => event
          }
        end,
        provider: provider,
        policy_run: local_policy_run(provider, { recommendation_count: events.length }),
        tool_invocations: []
      }
    end

    def positive_local_event_time_range?(event)
      attrs = event.respond_to?(:to_h) ? event.to_h : {}
      start_at = parse_context_time(attrs['start_at'] || attrs[:start_at])
      end_at = parse_context_time(attrs['end_at'] || attrs[:end_at])
      start_at.present? && end_at.present? && end_at > start_at
    end

    def invalid_generated_event_time_range_response
      {
        assistant_message: '終了時刻が開始時刻より後になるように指定してください。候補はまだ作成していません。',
        recommendations: [],
        provider: 'rails-local-time-range-validation-v1',
        policy_run: local_policy_run('rails-local-time-range-validation-v1', { invalid_generated_range: true }),
        tool_invocations: []
      }
    end

    def local_policy_run(provider, metadata = {})
      {
        provider: provider,
        policy_version: provider,
        route: 'rails_local_structured_parser',
        request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
        prompt_snapshot: { user_message: @user_message, scope: context_value(:scope) },
        context_snapshot: { timezone: context_value(:timezone), now: context_value(:now) },
        result_metadata: metadata
      }
    end

    def inferred_date_for_time_only(start_minute)
      return nil unless start_minute

      now = context_now
      candidate = app_time_zone.local(now.year, now.month, now.day, start_minute / 60, start_minute % 60, 0)
      candidate >= now ? now.to_date : now.to_date + 1
    end

    def build_local_event_payload(title:, date:, text:, start_minute: nil, end_minute: nil, duration_minutes: nil, default_duration: 60, contact_name: nil, participant_names: [], location: nil, buffer_minutes: nil, all_day: false)
      final_title = title.presence || local_event_descriptor(text)[:title]
      final_title = clean_activity_title(final_title)
      all_day_requested = ActiveModel::Type::Boolean.new.cast(all_day) || explicit_all_day_request?(text)
      start_minute ||= default_start_minute_for_text(text, final_title) unless all_day_requested
      return nil if negative_duration_expression_match(text)
      return nil if !duration_minutes.nil? && (!duration_minutes.is_a?(Numeric) || !duration_minutes.positive?)

      if all_day_requested
        start_at = app_time_zone.local(date.year, date.month, date.day, 0, 0, 0)
        end_at = start_at + 1.day
        all_day = true
      else
        duration = duration_minutes || default_duration
        return nil unless duration.is_a?(Numeric) && duration.positive?

        start_at = local_time_at_minute(date, start_minute)
        return nil unless start_at

        end_at = if end_minute
                   local_time_at_minute(date, end_minute)
                 else
                   start_at + duration.minutes
                 end
        return nil unless end_at && end_at > start_at
        all_day = false
      end

      local_event_hash(
        title: final_title,
        start_at: start_at,
        end_at: end_at,
        all_day: all_day,
        color: color_for_local_title(final_title),
        category: category_for_local_title(final_title),
        intent: intent_for_local_title(final_title),
        schedule_profile: profile_for_local_title(final_title),
        reason: local_reason_for_participants(participant_names),
        contact_name: contact_name,
        participant_names: participant_names,
        location: location,
        buffer_minutes: buffer_minutes
      )
    end

    def local_time_at_minute(date, minute)
      return nil unless date && minute.is_a?(Numeric) && minute >= 0

      day_offset, minute_of_day = minute.to_i.divmod(24 * 60)
      local_date = date + day_offset
      requested_hour = minute_of_day / 60
      requested_minute = minute_of_day % 60
      local_clock = Time.utc(
        local_date.year,
        local_date.month,
        local_date.day,
        requested_hour,
        requested_minute,
        0
      )
      return nil unless app_time_zone.tzinfo.periods_for_local(local_clock).one?

      resolved = app_time_zone.local(
        local_date.year,
        local_date.month,
        local_date.day,
        requested_hour,
        requested_minute,
        0
      )
      return nil unless resolved.to_date == local_date && resolved.hour == requested_hour && resolved.min == requested_minute

      resolved
    rescue ArgumentError, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime
      nil
    end

    def local_event_duration_minutes(event)
      return nil unless event.respond_to?(:to_h)

      attrs = event.to_h
      start_at = parse_context_time(attrs['start_at'] || attrs[:start_at])
      end_at = parse_context_time(attrs['end_at'] || attrs[:end_at])
      return nil unless start_at && end_at && end_at > start_at

      ((end_at - start_at) / 60).round
    end

    def local_period_date_range_from_text(text)
      source = normalize_japanese_preserve_case(text)
      now = context_now

      if (match = source.match(/(?:(?<sy>\d{4})年)?(?<sm>1[0-2]|0?[1-9])(?:月|[\/\-])(?<sd>3[01]|[12]\d|0?[1-9])日?\s*(?:から|〜|~|-)\s*(?:(?<ey>\d{4})年)?(?:(?<em>1[0-2]|0?[1-9])(?:月|[\/\-]))?(?<ed>3[01]|[12]\d|0?[1-9])日?(?:まで)?(?<tail>[^、。]*)/))
        start_date = local_date_from_parts(year: match[:sy], month: match[:sm], day: match[:sd], now: now)
        end_date = local_date_from_parts(year: match[:ey] || match[:sy], month: match[:em] || match[:sm], day: match[:ed], now: now)
        return { start_date: start_date, end_date: end_date, tail: match[:tail].to_s } if start_date && end_date
      end

      if (match = source.match(/(?<!\d)(?<sd>3[01]|[12]\d|0?[1-9])日\s*(?:から|〜|~|-)\s*(?<ed>3[01]|[12]\d|0?[1-9])日?(?:まで)?(?<tail>[^、。]*)/))
        start_date = local_date_from_parts(year: nil, month: nil, day: match[:sd], now: now)
        end_date = local_date_from_parts(year: start_date&.year, month: start_date&.month, day: match[:ed], now: now) if start_date
        end_date = end_date.next_month if start_date && end_date && end_date < start_date
        return { start_date: start_date, end_date: end_date, tail: match[:tail].to_s } if start_date && end_date
      end

      if (match = source.match(/(?<srel>再来週|来週|翌週|今週|次の)?(?:の)?\s*(?<sw>[月火水木金土日])(?:曜日|曜)?\s*(?:から|〜|~|-)\s*(?:(?<erel>再来週|来週|翌週|今週|次の)?(?:の)?\s*)?(?<ew>[月火水木金土日])(?:曜日|曜)?(?:まで)?(?<tail>[^、。]*)/))
        start_weekday = WEEKDAY_MAP[match[:sw]]
        end_weekday = WEEKDAY_MAP[match[:ew]]
        return nil unless start_weekday && end_weekday

        start_date = weekday_date_for_period_range(match[:srel], start_weekday, now)
        end_date = weekday_date_for_period_range(match[:erel].presence || match[:srel], end_weekday, now, base_date: start_date)
        end_date += 7 if start_date && end_date && end_date < start_date
        return { start_date: start_date, end_date: end_date, tail: match[:tail].to_s } if start_date && end_date
      end

      nil
    end

    def weekday_date_for_period_range(relative_word, weekday, now, base_date: nil)
      if relative_word.blank? && base_date
        return base_date + ((weekday - base_date.wday) % 7)
      end

      date = case relative_word.to_s
             when '再来週'
               week_start = beginning_of_week(now.to_date) + 14
               week_start + ((weekday - week_start.wday) % 7)
             when '来週', '翌週'
               week_start = beginning_of_week(now.to_date) + 7
               week_start + ((weekday - week_start.wday) % 7)
             when '今週'
               week_start = beginning_of_week(now.to_date)
               week_start + ((weekday - week_start.wday) % 7)
             when '次の'
               candidate = next_weekday_on_or_after(now.to_date, weekday)
               candidate == now.to_date ? candidate + 7 : candidate
             else
               next_weekday_on_or_after(now.to_date, weekday)
             end

      relative_word.to_s == '今週' && date < now.to_date ? date + 7 : date
    end

    def local_event_hash(title:, start_at:, end_at:, all_day:, color:, category:, intent:, schedule_profile:, reason:, contact_name: nil, participant_names: [], location: nil, buffer_minutes: nil)
      names = Array(participant_names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      payload = {
        'title' => title,
        'description' => local_description_for_payload(contact_name: contact_name, participant_names: names, buffer_minutes: buffer_minutes),
        'start_at' => start_at.iso8601,
        'end_at' => end_at.iso8601,
        'all_day' => all_day,
        'color' => color,
        'category' => category,
        'intent' => intent,
        'schedule_profile' => schedule_profile,
        'reason' => reason
      }
      payload['contact_name'] = contact_name.to_s.strip if contact_name.to_s.strip.present?
      payload['participant_names'] = names if names.any?
      payload['location'] = location.to_s.strip if location.to_s.strip.present?
      payload['buffer_minutes'] = buffer_minutes.to_i if buffer_minutes.to_i.positive?
      payload['relation_tags'] = ['contact'] if names.any? || contact_name.to_s.strip.present?
      payload
    end

    def local_description_for_payload(contact_name:, participant_names:, buffer_minutes:)
      parts = ['AI秘書提案の予定候補']
      names = Array(participant_names).presence || [contact_name].compact
      parts << "相手: #{names.join('・')}" if names.any?
      parts << "前後バッファ: #{buffer_minutes}分" if buffer_minutes.to_i.positive?
      parts.join(' / ')
    end

    def parse_local_event_items(text, clauses: nil)
      event_clauses = (clauses || schedule_event_clauses(text)).reject do |clause|
        weekday_multi_trailing_control_clause?(clause)
      end
      title_sources = multi_event_title_sources(text, event_clauses)

      event_clauses.each_with_index.filter_map do |original_clause, index|
        date = first_local_date_from_text(original_clause)
        next unless date

        original_descriptor = local_event_descriptor(original_clause)
        title_descriptor = multi_event_title_descriptor(title_sources[index])
        title = clean_activity_title(title_descriptor[:title])
        activity_title = clean_activity_title(title_descriptor[:activity_title])
        timing = parse_local_schedule_timing(
          original_clause,
          default_duration: default_duration_minutes_for_title(activity_title)
        )
        {
          date: date,
          title: title,
          activity_title: activity_title,
          contact_name: original_descriptor[:contact_name],
          participant_names: original_descriptor[:participant_names],
          location: original_descriptor[:location],
          buffer_minutes: original_descriptor[:buffer_minutes],
          start_minute: timing[:start_minute] || default_start_minute_for_text(original_clause, activity_title),
          end_minute: timing[:end_minute],
          duration_minutes: timing[:duration_minutes] || default_duration_minutes_for_title(activity_title),
          text: original_clause
        }
      end
    end

    def schedule_event_clauses(text)
      split_event_clauses(text).select { |clause| schedule_event_clause?(clause) }
    end

    def schedule_event_clause?(clause)
      return false if clause.blank?

      descriptor = local_event_descriptor(clause)
      title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
      return false if schedule_event_framing_clause?(clause, title)

      explicit_time_present?(clause) ||
        first_local_date_from_text(clause).present? ||
        target_weekdays(clause).any? ||
        (title.present? && title != '予定' && !insufficient_activity_title?(title) && !request_phrase_only?(title))
    end

    def schedule_event_framing_clause?(clause, title)
      normalized_clause = normalize_japanese(clause).strip
      normalized_title = normalize_japanese(title).strip

      return true if normalized_clause.match?(/[:：]\z/) && !explicit_time_present?(normalized_clause)

      normalized_title.match?(
        /\A(?:予定候補(?:一覧)?|予定一覧|候補一覧|以下(?:の予定(?:候補)?)?|以上(?:です)?|よろしく(?:お願いします?)?|ありがとう(?:ございます)?)\z/
      )
    end

    def split_event_clauses(text, preserve_case: false)
      normalized = if preserve_case
                     normalize_japanese_preserve_case(text)
                   else
                     normalize_japanese(text)
                   end
      normalized = normalize_validated_list_markers(normalized)
      normalized = normalized.gsub(
        /((?:\d{1,2}[:：]\d{2}|\d{1,2}時(?!間)(?:\d{1,2}分?|半)?))\s*[・･]\s*(?=-?\d+(?:\.\d+)?\s*(?:時間\s*半|時間|分))/,
        '\\1 '
      )
      normalized
        .split(/(?:\r?\n|。|,|;|；|そして|それから)/)
        .flat_map { |clause| split_safe_period_event_clauses(clause) }
        .flat_map { |clause| split_japanese_comma_event_clauses(clause) }
        .flat_map { |clause| split_interpunct_event_clauses(clause) }
        .map(&:strip)
        .reject(&:blank?)
    end

    def split_safe_period_event_clauses(text)
      source = text.to_s
      boundaries = safe_period_event_boundary_indexes(source)
      return [source] if boundaries.empty?

      fragments = []
      fragment_start = 0
      boundaries.each do |boundary_index|
        fragments << source[fragment_start...boundary_index]
        fragment_start = boundary_index + 1
      end
      fragments << source[fragment_start...source.length]
      fragments.map(&:strip).reject(&:blank?)
    end

    def safe_period_event_boundary_indexes(source)
      delimiter_scan = scan_protected_text_delimiters(source)
      return [] if delimiter_scan[:error]

      protected_spans = non_overlapping_text_spans(
        delimiter_scan[:spans] + domain_like_text_spans(source) + abbreviation_like_text_spans(source)
      )
      boundaries = []
      fragment_start = 0
      protected_span_index = 0
      temporal_signal_prefix = period_temporal_signal_prefix(source)

      source.each_char.with_index do |character, index|
        next unless character == '.'

        while protected_spans[protected_span_index] && protected_spans[protected_span_index].end <= index
          protected_span_index += 1
        end
        next if protected_spans[protected_span_index]&.cover?(index)
        next unless period_right_temporal_anchor_at?(source, index + 1)
        next unless safe_period_event_boundary?(source, index, fragment_start, temporal_signal_prefix)

        boundaries << index
        fragment_start = index + 1
      end

      boundaries
    end

    def unmatched_closing_text_delimiter?(text)
      scan_protected_text_delimiters(text)[:error].present?
    end

    def safe_period_event_boundary?(source, index, fragment_start, temporal_signal_prefix)
      previous_character = index.positive? ? source[index - 1] : nil
      return false if previous_character&.match?(/\d/)
      return false if period_left_ambiguous_numeric_marker?(source, fragment_start, index)
      return false unless temporal_signal_prefix[index] > temporal_signal_prefix[fragment_start]

      true
    end

    def period_temporal_signal_prefix(source)
      structural_source = mask_multi_event_structural_literals(source)
      signal_starts = explicit_clock_scan(structural_source)[:tokens].map { |token| token[:start_index] }
      temporal_pattern = /(?:
        今日|きょう|明日|あした|明後日|あさって|
        (?:(?:再来週|来週|翌週|今週|次の)の?[ \t　]*)?[月火水木金土日](?:曜日|曜)|
        (?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])月(?:3[01]|[12]\d|0?[1-9])日?|
        (?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])[\/-](?:3[01]|[12]\d|0?[1-9])日?|
        (?<!\d)(?:3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])
      )/x
      structural_source.to_enum(:scan, temporal_pattern).each do
        signal_starts << Regexp.last_match.begin(0)
      end

      starts_by_index = Array.new(source.length + 1, 0)
      signal_starts.uniq.each { |start_index| starts_by_index[start_index + 1] = 1 }
      1.upto(source.length) do |index|
        starts_by_index[index] += starts_by_index[index - 1]
      end
      starts_by_index
    end

    def period_left_ambiguous_numeric_marker?(source, fragment_start, period_index)
      cursor = period_index - 1
      cursor -= 1 while cursor >= fragment_start && source[cursor]&.match?(/[ \t　]/)
      digit_end = cursor
      cursor -= 1 while cursor >= fragment_start && source[cursor]&.match?(/\d/)
      digit_count = digit_end - cursor
      return false unless digit_count.between?(1, 2)

      cursor < fragment_start || source[cursor]&.match?(/[\s　:：、,]/)
    end

    def period_right_temporal_anchor_at?(source, start_index)
      anchor_index = start_index
      anchor_index += 1 while source[anchor_index]&.match?(/[ \t　]/)
      return false if anchor_index >= source.length

      probe = source[anchor_index, 96].to_s
      return true if probe.match?(
        /\A(?:(?:(?:再来週|来週|翌週|今週|次の)の?[ \t　]*)?[\u6708火水木金土日](?:曜日|曜)?)/
      )
      return true if probe.match?(/\A(?:今日|きょう|明日|あした|明後日|あさって)/)
      return true if probe.match?(/\A(?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])月(?:3[01]|[12]\d|0?[1-9])日?/)
      return true if probe.match?(/\A(?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])[\/-](?:3[01]|[12]\d|0?[1-9])日?/)
      return true if probe.match?(/\A(?<!\d)(?:3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/)

      scan = explicit_clock_scan(probe)
      token = scan[:tokens].first
      token.present? && token[:start_index].zero?
    end

    def protected_text_spans(text)
      scan_protected_text_delimiters(text)[:spans]
    end

    def scan_protected_text_delimiters(text)
      source = text.to_s
      preliminary_scan = scan_text_delimiters(
        source,
        ignored_closing_byte_indexes: {}
      )
      numbered_list_closing_byte_indexes = numbered_list_closing_delimiter_byte_indexes(
        source,
        matched_closing_byte_indexes: preliminary_scan[:matched_closing_byte_indexes]
      )
      final_scan = scan_text_delimiters(
        source,
        ignored_closing_byte_indexes: numbered_list_closing_byte_indexes
      )

      { spans: final_scan[:spans], error: final_scan[:error] }
    end

    def scan_text_delimiters(source, ignored_closing_byte_indexes:)
      spans = []
      stack = []
      active_symmetric = {}
      characters = source.each_char.to_a
      matched_closing_byte_indexes = {}
      byte_index = 0
      error = nil

      characters.each_with_index do |character, index|
        current_byte_index = byte_index
        byte_index += character.bytesize

        next if character == "'" && ascii_apostrophe_inside_word?(characters, index)
        if ignored_closing_byte_indexes.key?(current_byte_index) &&
           (stack.empty? || character == stack.last[:closing])
          next
        end

        if stack.any? && character == stack.last[:closing]
          opened = stack.pop
          active_symmetric.delete(opened[:opening]) if opened[:opening] == opened[:closing]
          spans << (opened[:start_index]...(index + 1)) if stack.empty?
          matched_closing_byte_indexes[current_byte_index] = opened.merge(
            end_index: index + 1,
            end_byte_index: byte_index
          )
          next
        end

        if (closing = PROTECTED_TEXT_DELIMITER_PAIRS[character])
          if closing == character && active_symmetric.key?(character)
            error ||= {
              kind: :mismatched_closing,
              opening: stack.last&.fetch(:opening, nil),
              closing: character,
              index: index,
              outermost_opening_index: stack.first&.fetch(:start_index, nil)
            }
            next
          end

          stack << {
            opening: character,
            closing: closing,
            depth: stack.length + 1,
            start_index: index,
            start_byte_index: current_byte_index,
            preceding_text: characters[[index - 48, 0].max...index].join
          }
          active_symmetric[character] = true if closing == character
          next
        end

        next unless PROTECTED_TEXT_ASYMMETRIC_CLOSINGS.key?(character)

        error ||= {
          kind: stack.empty? ? :unmatched_closing : :mismatched_closing,
          opening: stack.last&.fetch(:opening, nil),
          closing: character,
          index: index,
          outermost_opening_index: stack.first&.fetch(:start_index, nil)
        }
      end

      if error.nil? && stack.any?
        error = {
          kind: :unmatched_opening,
          opening: stack.last[:opening],
          closing: nil,
          index: stack.last[:start_index],
          outermost_opening_index: stack.first[:start_index]
        }
      end
      spans << (stack.first[:start_index]...characters.length) if stack.any?

      {
        spans: spans,
        error: error,
        matched_closing_byte_indexes: matched_closing_byte_indexes
      }
    end

    def numbered_list_closing_delimiter_byte_indexes(text, matched_closing_byte_indexes:)
      markers = raw_list_item_marker_candidates(text)

      inline_start_indexes = inline_numbered_list_start_byte_indexes(
        text,
        markers,
        matched_closing_byte_indexes: matched_closing_byte_indexes
      )
      first_marker_index = markers.index do |marker|
        next false if matched_closing_byte_indexes.key?(marker[:marker_start_byte_index])

        boundary = marker[:boundary].to_s
        boundary.empty? || boundary.include?("\n") || inline_start_indexes.key?(marker[:number_start_byte_index])
      end
      return {} unless first_marker_index

      list_markers = markers[first_marker_index..]
      if list_markers.one? &&
          text.to_s.byteslice(list_markers.first[:end_byte_index]...).to_s.strip.blank?
        return {}
      end

      last_marker_index_by_number = {}
      list_markers.each_with_index do |marker, index|
        last_marker_index_by_number[marker[:number]] = index
      end

      previous_structural_number = nil
      list_markers.each_with_index.each_with_object({}) do |(marker, index), indexes|
        if [')', '）'].include?(marker[:marker])
          matched_closing = matched_closing_byte_indexes[marker[:marker_start_byte_index]]
          if matched_closing &&
              numeric_list_qualifier_closing?(
                text,
                marker,
                matched_closing,
                previous_list_number: previous_structural_number,
                later_same_number: last_marker_index_by_number[marker[:number]] > index,
                next_marker: list_markers[index + 1],
                next_marker_preliminarily_balanced: list_markers[index + 1] &&
                  matched_closing_byte_indexes.key?(
                    list_markers[index + 1][:marker_start_byte_index]
                  )
              )
            next
          end

          indexes[marker[:marker_start_byte_index]] = true
        end
        previous_structural_number = marker[:number]
      end
    end

    def numeric_list_qualifier_closing?(
      text,
      marker,
      matched_closing,
      previous_list_number:,
      later_same_number:,
      next_marker:,
      next_marker_preliminarily_balanced:
    )
      return false unless ['(', '（'].include?(matched_closing[:opening])
      return false if marker[:boundary].to_s.match?(/[\r\n]/)
      return true if normalize_japanese(marker[:boundary]) == ':'
      return true if later_same_number
      return true if matched_closing[:depth].to_i > 1 &&
                     raw_horizontal_space_only?(marker[:boundary])
      return true if previous_list_number && marker[:number] != previous_list_number + 1
      return false if next_marker &&
                      next_marker[:number] == marker[:number] + 1 &&
                      !next_marker_preliminarily_balanced
      return false if compact_numbered_list_marker_bound_temporal_body?(text, marker)
      return true if numeric_qualifier_direct_title_continuation?(
        text,
        marker,
        matched_closing,
        next_marker: next_marker
      )
      return false if structurally_separated_numbered_list_marker?(text, marker)
      return true if numeric_qualifier_opening_attached_to_title?(matched_closing)
      return true if list_marker_trailing_body_blank?(
        text,
        marker,
        next_marker: next_marker
      )

      content_start_byte_index =
        matched_closing[:start_byte_index] + matched_closing[:opening].bytesize
      content_end_byte_index = marker[:number_start_byte_index]
      return false if content_end_byte_index < content_start_byte_index

      qualifier_prefix = text.to_s.byteslice(
        content_start_byte_index,
        content_end_byte_index - content_start_byte_index
      ).to_s
      normalize_japanese(qualifier_prefix).strip.match?(
        /\A(?:phase|version|ver|v|no\.?|part|step|section)?\z/i
      )
    end

    def compact_numbered_list_marker_bound_temporal_body?(text, marker)
      closing_end_byte_index = marker[:marker_start_byte_index] + marker[:marker].bytesize
      return false if horizontal_space_end_byte_index(text.to_s, closing_end_byte_index) >
                      closing_end_byte_index

      body = numeric_list_marker_trailing_probe(text, closing_end_byte_index)
      numeric_list_item_body_starts_with_bound_temporal_anchor?(body)
    end

    def numeric_qualifier_direct_title_continuation?(text, marker, matched_closing, next_marker:)
      normalized_qualifier = numeric_qualifier_label(text, marker, matched_closing)
      return false if normalized_qualifier.blank? || normalized_qualifier.length > 32
      return false unless normalized_qualifier.match?(/\A[\p{L}\p{N}._ -]+\z/)

      closing_end_byte_index = marker[:marker_start_byte_index] + marker[:marker].bytesize
      return false if horizontal_space_end_byte_index(text.to_s, closing_end_byte_index) >
                      closing_end_byte_index

      trailing_end_byte_index = next_marker&.fetch(:start_byte_index, nil) || text.to_s.bytesize
      trailing = text.to_s.byteslice(
        closing_end_byte_index,
        trailing_end_byte_index - closing_end_byte_index
      ).to_s.scrub
      return false if trailing.blank?

      normalized = normalize_japanese(trailing)
      return false if normalized.match?(/[、,，。｡;；!！?？\r\n]/)

      title_continuation = normalized.sub(/[」』】］\]\)）”’"']+\z/, '')
      return title_continuation.present? if raw_horizontal_space_only?(marker[:boundary])

      title_continuation.match?(
        /(?:
          レビュー | 版(?:レビュー)? | (?:の)?確認 | 予約 | 対応 | 定例 |
          テスト | 検証 | 更新 | 会議 | 設計 | 実装 | 調査 | 検討 |
          チェック | 修正 | 改善 | 作業 | 資料 | メモ | 議事録
        )\z/x
      )
    end

    def numeric_qualifier_label(text, marker, matched_closing)
      content_start_byte_index =
        matched_closing[:start_byte_index] + matched_closing[:opening].bytesize
      qualifier = text.to_s.byteslice(
        content_start_byte_index,
        marker[:number_start_byte_index] - content_start_byte_index
      ).to_s

      normalize_japanese(qualifier)
        .strip
        .sub(/[:：、,，;；]\z/, '')
        .strip
    end

    def structurally_separated_numbered_list_marker?(text, marker)
      boundary = marker[:boundary].to_s
      closing_end_byte_index = marker[:marker_start_byte_index] + marker[:marker].bytesize
      body_start_byte_index = horizontal_space_end_byte_index(text.to_s, closing_end_byte_index)
      return false if body_start_byte_index >= text.to_s.bytesize

      return true if boundary.empty? || boundary.include?("\n") || boundary.include?("\r")
      return true unless raw_horizontal_space_only?(boundary)
      return true if body_start_byte_index > closing_end_byte_index

      body = numeric_list_marker_trailing_probe(text, body_start_byte_index)
      numeric_list_item_body_starts_with_bound_temporal_anchor?(body)
    end

    def numeric_list_item_body_starts_with_bound_temporal_anchor?(body)
      normalized = normalize_japanese(body)
      clock_scan = explicit_clock_scan(normalized)
      clock = clock_scan[:tokens].first
      if clock && clock[:start_index].zero?
        clock_tail = clock_scan[:source][clock[:end_index]...].to_s
        return true if numeric_list_temporal_binding_tail?(clock_tail)
      end

      temporal_label = normalized.match(NUMERIC_QUALIFIER_TEMPORAL_BODY_START_PATTERN)
      return false unless temporal_label

      label_tail = normalized[temporal_label.end(0)...].to_s
      return true if numeric_list_temporal_binding_tail?(label_tail)

      period = label_tail.match(NUMERIC_QUALIFIER_PERIOD_BODY_START_PATTERN)
      label_tail = label_tail[period.end(0)...].to_s if period
      return true if period && numeric_list_temporal_binding_tail?(label_tail)
      return true if period && label_tail.match?(
        /\A[ \t　]*(?:#{SCHEDULE_SYNTAX_ACTIVITY_PATTERN.source})/x
      )

      tail_clock_scan = explicit_clock_scan(label_tail)
      tail_clock = tail_clock_scan[:tokens].first
      tail_clock && tail_clock[:start_index].zero? &&
        numeric_list_temporal_binding_tail?(
          tail_clock_scan[:source][tail_clock[:end_index]...].to_s
        )
    end

    def numeric_list_temporal_binding_tail?(tail)
      binding = tail.to_s.match(
        /\A[ \t　]*(?:(?:頃|ごろ)[ \t　]*)?(?:は|に|で|の|へ|から|まで|以降|以前|開始|中)/
      )
      return false unless binding

      remainder = tail.to_s[binding.end(0)...].to_s.lstrip
      !remainder.match?(/\A(?:関する|ついて|向け|用(?:の|に)?)/)
    end

    def numeric_list_marker_trailing_probe(text, closing_end_byte_index)
      text.to_s.byteslice(
        closing_end_byte_index,
        NUMERIC_LIST_MARKER_LOOKAHEAD_BYTES
      ).to_s.scrub
    end

    def numeric_qualifier_opening_attached_to_title?(matched_closing)
      prefix = normalize_japanese(matched_closing[:preceding_text]).rstrip
      return false if prefix.blank?
      return false if numeric_qualifier_temporal_anchor_suffix?(prefix)

      prefix[-1].match?(/[\p{L}\p{N}\]）】」』”’]/)
    end

    def numeric_qualifier_temporal_anchor_suffix?(prefix)
      return true if prefix.match?(NUMERIC_QUALIFIER_TEMPORAL_ANCHOR_PATTERN)

      clock_scan = explicit_clock_scan(prefix)
      clock = clock_scan[:tokens].last
      return false unless clock

      clock_scan[:source][clock[:end_index]...].to_s.strip.match?(
        /\A(?:(?:は|に|で|の|から|まで|頃|ごろ|以降|以前|開始|間|中)[ \t　]*){0,3}\z/
      )
    end

    def list_marker_trailing_body_blank?(text, marker, next_marker:)
      body_end_byte_index =
        next_marker&.fetch(:start_byte_index, nil) || text.to_s.bytesize
      body = text.to_s.byteslice(
        marker[:end_byte_index],
        body_end_byte_index - marker[:end_byte_index]
      ).to_s

      normalized = normalize_japanese(body)
                   .gsub(/\A[ \t　、,，。｡;；.!！?？]+|[ \t　、,，。｡;；.!！?？]+\z/, '')
                   .strip
      return true if normalized.blank?

      fragments = normalized.split(/[。\r\n、,，;；]/).map(&:strip).reject(&:blank?)
      fragments.any? && fragments.all? do |fragment|
        fragment.match?(
          /\A(?:
            (?:保存|登録|追加)(?:は|を)?(?:しないで(?:ください)?|しない|しません|せず|不要|なし) |
            (?:担当者|通知(?:先)?|担当者(?:や|と)通知(?:先)?)(?:は|を)?
            設定(?:しないで(?:ください)?|しない|しません|せず|不要|なし) |
            予定候補(?:だけ|のみ)?(?:を)?(?:整理|確認)(?:して)?(?:ください)?
          )\z/x
        )
      end
    end

    def raw_list_item_marker_candidates(text)
      source = text.to_s
      markers = []

      source.to_enum(:scan, LIST_ITEM_MARKER_TOKEN_PATTERN).each do
        match = Regexp.last_match
        number_start_byte_index = match.byteoffset(:number).first
        boundary = list_item_marker_boundary_before(source, number_start_byte_index)
        next unless boundary
        next if match[:marker] == '、' && raw_horizontal_space_only?(boundary[:value])

        match_start_byte_index = boundary[:start_byte_index]
        start_byte_index = match_start_byte_index
        start_byte_index += boundary[:value].bytesize if boundary[:value].match?(/\A[:：]\z/)

        markers << {
          boundary: boundary[:value],
          number: match[:number].tr('０-９', '0-9').to_i,
          marker: match[:marker],
          match_start_byte_index: match_start_byte_index,
          start_byte_index: start_byte_index,
          end_byte_index: match.byteoffset(0).last,
          number_start_byte_index: number_start_byte_index,
          marker_start_byte_index: match.byteoffset(:marker).first
        }
      end

      markers
    end

    def list_item_marker_boundary_before(source, number_start_byte_index)
      cursor = horizontal_space_start_byte_index(source, number_start_byte_index)

      return { value: '', start_byte_index: 0 } if cursor.zero?

      literal = LIST_ITEM_BOUNDARY_LITERALS.find do |candidate|
        candidate_size = candidate.bytesize
        cursor >= candidate_size &&
          source.byteslice(cursor - candidate_size, candidate_size) == candidate
      end
      if literal
        return {
          value: literal,
          start_byte_index: cursor - literal.bytesize
        }
      end

      return nil if cursor == number_start_byte_index

      {
        value: source.byteslice(cursor, number_start_byte_index - cursor),
        start_byte_index: cursor
      }
    end

    def inline_numbered_list_start_byte_indexes(text, markers, matched_closing_byte_indexes:)
      indexes = {}
      line_start_byte_index = 0
      marker_index = 0

      text.to_s.each_line do |line|
        line_end_byte_index = line_start_byte_index + line.bytesize
        line_markers = []
        while marker_index < markers.length &&
              markers[marker_index][:number_start_byte_index] < line_end_byte_index
          line_markers << markers[marker_index]
          marker_index += 1
        end

        inline_markers = line_markers.reject do |marker|
          marker[:boundary].empty? || marker[:boundary].include?("\n")
        end
        inline_markers.reject! do |marker|
          matched_closing_byte_indexes.key?(marker[:marker_start_byte_index])
        end
        marker = inline_markers.find { |candidate| [':', '：'].include?(candidate[:boundary]) } ||
                 inline_markers.first
        if marker
          prefix_byte_length = marker[:number_start_byte_index] - line_start_byte_index
          prefix = line.byteslice(0, prefix_byte_length).to_s
          normalized_prefix = normalize_japanese(prefix)
          if normalized_prefix.match?(LIST_CONTINUATION_PREFIX_PATTERN) ||
              schedule_list_heading_before_marker?(prefix)
            indexes[marker[:number_start_byte_index]] = true
          end
        end
        line_start_byte_index = line_end_byte_index
      end

      indexes
    end

    def ascii_apostrophe_inside_word?(characters, index)
      previous_character = index.positive? ? characters[index - 1] : nil
      following_character = characters[index + 1]
      return false unless previous_character&.match?(/[\p{L}\p{N}]/) &&
                          following_character&.match?(/[\p{L}\p{N}]/)

      latin_or_number = /[\p{Latin}\p{N}]/
      (previous_character.match?(latin_or_number) && following_character.match?(latin_or_number)) ||
        following_character.match?(/[sS]/)
    end

    def text_range_protected?(spans, range)
      spans.any? { |span| range.begin < span.end && range.end > span.begin }
    end

    def normalize_validated_list_markers(text)
      markers = validated_list_marker_sequence(text)
      return text unless markers

      heading_qualifier_range = inline_list_heading_qualifier_range(text, markers.first)
      normalized = text.dup
      markers.reverse_each do |marker|
        normalized[marker[:start_index]...marker[:end_index]] = "\n"
      end
      normalized[heading_qualifier_range] = '' if heading_qualifier_range
      normalized
    end

    def inline_list_heading_qualifier_range(text, first_marker)
      prefix = text.to_s[0...first_marker[:match_start_index]].to_s
      return nil unless schedule_list_heading_before_marker?(prefix)

      terminal_balanced_heading_qualifier_range(prefix)
    end

    def validated_list_marker_sequence(text)
      markers = list_item_marker_candidates(text)
      select_validated_list_marker_sequence(text, markers)
    end

    def select_validated_list_marker_sequence(text, markers)
      return nil unless markers.length >= 2

      chains = []
      memo = {}
      markers.each_index do |first_index|
        skipped_prefix = markers[0...first_index]
        next unless skipped_prefix.each_with_index.all? do |marker, index|
          numeric_title_marker_candidate?(text, marker, markers[index + 1])
        end
        first_marker = markers[first_index]
        next unless list_item_sequence_start?(text, first_marker)
        next unless valid_numbered_list_start?(text, first_marker)

        valid_list_marker_paths_from(
          text,
          markers,
          first_index,
          selected_count: 1,
          memo: memo
        ).each do |path|
          chains << path
          break if chains.length > 1
        end
        break if chains.length > 1
      end
      return nil unless chains.one?

      chains.first.map { |index| markers[index] }
    end

    def valid_list_marker_paths_from(text, markers, marker_index, selected_count:, memo:)
      memo_key = [marker_index, selected_count >= 2]
      return memo[memo_key] if memo.key?(memo_key)

      marker = markers[marker_index]
      tail_markers = markers[(marker_index + 1)..] || []
      paths = []

      if selected_count >= 2 &&
          tail_markers.each_with_index.all? do |marker, offset|
            numeric_title_marker_candidate?(text, marker, markers[marker_index + offset + 2])
          end &&
          valid_list_item_body?(text[marker[:end_index]...text.length])
        paths << [marker_index]
      end

      expected_number = marker[:number] + 1
      ((marker_index + 1)...markers.length).each do |following_index|
        following = markers[following_index]
        next unless following[:number] == expected_number

        skipped_markers = markers[(marker_index + 1)...following_index]
        next unless skipped_markers.each_with_index.all? do |marker, offset|
          numeric_title_marker_candidate?(text, marker, markers[marker_index + offset + 2])
        end
        next unless valid_list_item_body?(text[marker[:end_index]...following[:start_index]])

        valid_list_marker_paths_from(
          text,
          markers,
          following_index,
          selected_count: selected_count + 1,
          memo: memo
        ).each do |suffix|
          paths << [marker_index, *suffix]
          return memo[memo_key] = paths.first(2) if paths.length > 1
        end
      end

      memo[memo_key] = paths
    end

    def invalid_numbered_list_sequence_details(text)
      normalized = normalize_japanese(text)
      markers = list_item_marker_candidates(normalized)
      return nil unless markers.length >= 2
      first_marker = markers.each_with_index.find do |marker, index|
        ignorable_prefix = markers[0...index].each_with_index.all? do |prefix_marker, prefix_index|
          numeric_title_marker_candidate?(normalized, prefix_marker, markers[prefix_index + 1])
        end
        ignorable_prefix && numbered_list_candidate_start?(normalized, marker)
      end&.first
      return nil unless first_marker
      return nil if select_validated_list_marker_sequence(normalized, markers)

      unless valid_numbered_list_start?(normalized, first_marker)
        return {
          item_number: first_marker[:number],
          marker_count: markers.length
        }
      end

      mismatch = markers.each_cons(2).find do |current, following|
        following[:number] != current[:number] + 1
      end
      invalid_body = markers.each_with_index.find do |marker, index|
        body_end = markers[index + 1]&.fetch(:start_index) || normalized.length
        !valid_list_item_body?(normalized[marker[:end_index]...body_end])
      end

      {
        item_number: (mismatch&.last || invalid_body&.first || markers.last)[:number],
        marker_count: markers.length
      }
    end

    def list_item_marker_candidates(text)
      markers = []
      source = text.to_s
      protected_spans = protected_text_spans(source)
      raw_markers = raw_list_item_marker_candidates(source)
      byte_offsets = raw_markers.flat_map do |marker|
        [
          marker[:match_start_byte_index],
          marker[:start_byte_index],
          marker[:number_start_byte_index],
          marker[:end_byte_index]
        ]
      end
      character_indexes = character_indexes_for_byte_offsets(source, byte_offsets)

      raw_markers.each do |marker|
        number_start_index = character_indexes.fetch(marker[:number_start_byte_index])
        end_index = character_indexes.fetch(marker[:end_byte_index])
        next if text_range_protected?(
          protected_spans,
          number_start_index...end_index
        )

        marker = {
          boundary: marker[:boundary],
          number: marker[:number],
          number_start_index: number_start_index,
          match_start_index: character_indexes.fetch(marker[:match_start_byte_index]),
          start_index: character_indexes.fetch(marker[:start_byte_index]),
          end_index: end_index
        }
        markers << marker
      end
      markers
    end

    def character_indexes_for_byte_offsets(source, byte_offsets)
      target_offsets = byte_offsets.each_with_object({}) { |offset, targets| targets[offset] = true }
      indexes = {}
      byte_index = 0
      character_index = 0

      indexes[byte_index] = character_index if target_offsets.key?(byte_index)

      source.each_char do |character|
        byte_index += character.bytesize
        character_index += 1
        indexes[byte_index] = character_index if target_offsets.key?(byte_index)
      end

      indexes
    end

    def numeric_title_marker_candidate?(text, marker, following_marker)
      return false unless marker[:boundary] == '、'
      left_match = text[0...marker[:match_start_index]].to_s.rstrip.match(/(\d+)\z/)
      return false unless left_match
      step = marker[:number] - left_match[1].to_i
      return false unless step.positive?

      body_end = following_marker&.fetch(:start_index) || text.length
      body = text[marker[:end_index]...body_end].to_s.lstrip
      return false if interpunct_event_clause_start?(body)
      right_match = body.match(/\A(\d+)/)
      return false unless right_match && right_match[1].to_i - marker[:number] == step
      return false if body.match?(/\A\d+\s*(?:名|人)/)

      true
    end

    def numbered_schedule_context?(text)
      normalized = normalize_japanese(text)
      explicit_time_present?(normalized) ||
        first_local_date_from_text(normalized).present? ||
        target_weekdays(normalized).any? ||
        normalized.match?(/予定|スケジュール|カレンダー|入れて|追加|登録/)
    end

    def list_item_sequence_start?(text, marker)
      boundary = marker[:boundary]
      return true if boundary.empty? || boundary.include?("\n")
      return true if explicit_numbered_list_continuation_prefix?(text, marker)

      schedule_list_heading_before_marker?(text[0...marker[:number_start_index]])
    end

    def valid_numbered_list_start?(text, marker)
      marker[:number] == 1 ||
        (marker[:number].positive? && explicit_numbered_list_continuation_prefix?(text, marker))
    end

    def explicit_numbered_list_continuation_prefix?(text, marker)
      prefix = normalize_japanese(text.to_s[0...marker[:number_start_index]])
      prefix.match?(LIST_CONTINUATION_PREFIX_PATTERN)
    end

    def explicit_numbered_list_continuation_request?(text)
      list_item_marker_candidates(text).any? do |marker|
        explicit_numbered_list_continuation_prefix?(text, marker)
      end
    end

    def numbered_list_candidate_start?(text, marker)
      list_item_sequence_start?(text, marker) || noncontinuation_numbered_list_prefix?(text, marker)
    end

    def noncontinuation_numbered_list_prefix?(text, marker)
      prefix = normalize_japanese(text.to_s[0...marker[:number_start_index]])
      prefix.match?(LIST_NONCONTINUATION_PREFIX_PATTERN)
    end

    def schedule_list_heading_before_marker?(prefix)
      heading = prefix.to_s.split(/\r?\n/).last.to_s.strip
      heading_candidates = [heading]
      if (qualifier_range = terminal_balanced_heading_qualifier_range(heading))
        heading_candidates << heading[0...qualifier_range.begin].rstrip
      end

      heading_candidates.uniq.any? do |candidate|
        next false unless normalize_japanese(candidate).match?(/予定|候補|以下/)

        descriptor = local_event_descriptor(candidate)
        title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
        schedule_event_framing_clause?(candidate, title)
      end
    end

    def terminal_balanced_heading_qualifier_range(text)
      source = text.to_s.rstrip
      delimiter_scan = scan_text_delimiters(
        source,
        ignored_closing_byte_indexes: {}
      )
      return nil if delimiter_scan[:error]

      terminal_span = delimiter_scan[:spans].last
      return nil unless terminal_span && terminal_span.end == source.length && terminal_span.begin.positive?

      prefix = source[0...terminal_span.begin]
      trailing_space_length = prefix.match(/[ \t　]*\z/)[0].length
      qualifier_start_index = terminal_span.begin - trailing_space_length
      qualifier_start_index...source.length
    end

    def valid_list_item_body?(body)
      normalized = normalize_japanese(body).strip
      return false if normalized.blank? || normalized.match?(/\A\d+\z/)

      schedule_event_clause?(normalized)
    end

    def split_japanese_comma_event_clauses(clause)
      return [clause] unless clause.include?('、')

      fragments = clause.split(/(、)/, -1)
      segments = []
      current = fragments.shift.to_s

      fragments.each_slice(2) do |delimiter, right|
        right = right.to_s
        if japanese_comma_event_boundary?(current, right)
          segments << current
          current = right
        else
          current = "#{current}#{delimiter}#{right}"
        end
      end

      segments << current
      segments
    end

    def japanese_comma_event_boundary?(left, right)
      normalized_left = normalize_japanese(left).strip
      normalized_right = normalize_japanese(right).strip
      return false if normalized_left.blank? || normalized_right.blank?
      return false if pending_list_marker_before_comma?(normalized_left)
      return true if interpunct_event_clause_start?(normalized_right)
      return false if normalized_left.match?(/\d\z/) || normalized_right.match?(/\A\d/)
      return false if latin_compound_title_continuation?(normalized_left, normalized_right)

      interpunct_event_clause_start?(normalized_left) && schedule_event_clause?(normalized_right)
    end

    def latin_compound_title_continuation?(left, right)
      left_title = clean_activity_title(remove_date_time_phrases(left))
      right_title = clean_activity_title(remove_date_time_phrases(right))

      left_title.match?(/\A[\p{Latin}][\p{Latin}\d+.#&_-]*\z/) &&
        right_title.match?(/\A[\p{Latin}][\p{Latin}\d+.#&_-]*(?=[\p{Han}\p{Hiragana}\p{Katakana}])/)
    end

    def pending_list_marker_before_comma?(left)
      probe = "#{left.rstrip}、"
      marker = list_item_marker_candidates(probe).last
      marker.present? && marker[:end_index] == probe.length
    end

    def split_interpunct_event_clauses(clause)
      return [clause] unless clause.match?(/[・･]/)
      return [clause] if recurrence_request?(clause)

      fragments = clause.split(/([・･])/, -1)
      segments = []
      current = fragments.shift.to_s

      fragments.each_slice(2) do |delimiter, right|
        right = right.to_s
        if interpunct_event_clause_start?(right)
          segments << current
          current = right
        else
          current = "#{current}#{delimiter}#{right}"
        end
      end

      segments << current
      segments
    end

    def interpunct_event_clause_start?(text)
      normalized = normalize_japanese(text).strip
      return false if normalized.blank?

      target_weekdays(normalized).any? ||
        first_local_date_from_text(normalized).present? ||
        explicit_time_present?(normalized)
    end

    def candidate_dates_for_request(text)
      normalized = normalize_japanese(text)
      now = context_now
      weekdays = target_weekdays(normalized)

      if normalized.include?('再来週') || normalized.include?('翌週')
        start = now.to_date + ((8 - now.wday) % 7) + 7
        return weekdays.map { |weekday| start + ((weekday - start.wday) % 7) }.sort if weekdays.any?
        return (0..4).map { |i| start + i }
      end

      if normalized.include?('来週')
        start = now.to_date + ((8 - now.wday) % 7)
        return weekdays.map { |weekday| start + ((weekday - start.wday) % 7) }.sort if weekdays.any?
        return (0..4).map { |i| start + i }
      end

      if (date = first_local_date_from_text(text))
        return [date]
      end

      if weekdays.any?
        return weekdays.map { |weekday| next_weekday_on_or_after(now.to_date, weekday) }.sort
      end

      (0..10).map { |i| now.to_date + i }.select { |d| d.wday.between?(1, 5) }.first(7)
    end

    def first_local_date_from_text(text)
      now = context_now
      normalized = normalize_japanese(text)
      if (date = relative_day_count_date(normalized, now))
        return date
      end

      if (date = relative_final_weekday_date(normalized, now))
        return date
      end


      return now.to_date if normalized.include?('今日') || normalized.include?('きょう')
      return now.to_date + 1 if normalized.include?('明日') || normalized.include?('あした')
      return now.to_date + 2 if normalized.include?('明後日') || normalized.include?('あさって')

      if (date = relative_nth_weekday_date(normalized, now))
        return date
      end

      if (date = relative_weekday_date(normalized, now))
        return date
      end

      if normalized.include?('来月頭')
        year, month = add_months(now.year, now.month, 1)
        return Date.new(year, month, 1)
      end
      if normalized.include?('月末')
        target = Date.new(now.year, now.month, -1)
        return target >= now.to_date ? target : Date.new(*add_months(now.year, now.month, 1), -1)
      end
      if normalized.match?(/gw中|ゴールデンウィーク中/)
        target = Date.new(now.year, 5, 3)
        return target >= now.to_date ? target : Date.new(now.year + 1, 5, 3)
      end
      if normalized.match?(/gw明け|ゴールデンウィーク明け|連休明け/)
        target = Date.new(now.year, 5, 7)
        return target >= now.to_date ? target : Date.new(now.year + 1, 5, 7)
      end

      match = normalized.match(/(?:(?<year>\d{4})年)?(?<month>1[0-2]|0?[1-9])(?:月|[\/\-])(?<day>3[01]|[12]\d|0?[1-9])日?/)
      return local_date_from_parts(year: match[:year], month: match[:month], day: match[:day], now: now) if match

      match = normalized.match(/(?<!\d)(?<day>3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/)
      return local_date_from_parts(year: nil, month: now.month, day: match[:day], now: now) if match

      nil
    end

    def local_date_from_parts(year:, month:, day:, now:)
      date = Date.new(year.present? ? year.to_i : now.year, month.present? ? month.to_i : now.month, day.to_i)
      if year.blank? && date < now.to_date
        date = month.present? ? Date.new(date.year + 1, date.month, date.day) : date.next_month
      end
      date
    rescue StandardError
      nil
    end

    def local_event_descriptor(text, fallback_title: nil)
      activity_title = activity_title_from_text(text, fallback_title: fallback_title)
      names = participant_names_from_text(text)
      {
        title: compose_local_event_title(activity_title, names),
        activity_title: activity_title,
        participant_names: names,
        contact_name: names.first,
        location: extract_local_location(text),
        buffer_minutes: extract_local_buffer_minutes(text)
      }
    end

    def local_period_event_descriptor(text, fallback_title: nil, original_text: nil)
      source = clean_period_title_source(text)
      descriptor = local_event_descriptor(source.presence || original_text.to_s, fallback_title: fallback_title)
      location = extract_period_location(source).presence || descriptor[:location]
      title = clean_activity_title(source.presence || descriptor[:title])
      title = location if title == '予定' && location.present?

      descriptor.merge(
        title: title,
        activity_title: title,
        location: location
      )
    end

    def clean_period_title_source(text)
      remove_date_time_phrases(normalize_japanese_preserve_case(text))
        .gsub(/\A[\s、。,.，．・:：;；]*(?:に|へ|で|の|を|は|から|まで)+\s*/, '')
        .gsub(/\A[\s、。,.，．・:：;；]+|[\s、。,.，．・:：;；]+\z/, '')
        .strip
    end

    def extract_period_location(text)
      source = clean_activity_title(clean_period_title_source(text))
      return nil if source.blank? || source == '予定'

      if (match = source.match(/\A(?<place>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{2,30})(?:出張|旅行|滞在|観光|宿泊|帰省)\z/))
        place = clean_travel_place(match[:place])
        return place if valid_local_location?(place)
      end

      location = extract_local_location(source)
      return location if location.present?

      period_place_only_title?(source) ? source : nil
    end

    def period_place_only_title?(title)
      normalized = normalize_japanese(title)
      return false if normalized.blank? || normalized.length < 2
      return false if normalized.match?(/\A(?:予定|会議|打ち合わせ|打合せ|ミーティング|電話|作業|資料|メモ|確認|レビュー|飲み|飲み会|食事|旅行|出張|滞在|観光|宿泊|帰省|休み|休暇|勉強|学習|課題|営業|定例|面談|相談|挨拶|掃除|買い物|読書|洗濯|散歩|運動|通院|病院|ランチ|ディナー)\z/)
      return false if known_activity_title?(normalized)

      normalized.match?(/\A[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{2,30}\z/)
    end

    def period_travel_like_descriptor?(descriptor)
      title = descriptor[:title].to_s
      location = descriptor[:location].to_s
      location.present? && (title == location || title.match?(/旅行|出張|滞在|観光|宿泊|帰省/))
    end

    def color_for_period_descriptor(descriptor)
      period_travel_like_descriptor?(descriptor) ? '#f97316' : color_for_local_title(descriptor[:title])
    end

    def category_for_period_descriptor(descriptor)
      period_travel_like_descriptor?(descriptor) ? 'travel' : category_for_local_title(descriptor[:title])
    end

    def intent_for_period_descriptor(descriptor)
      period_travel_like_descriptor?(descriptor) ? 'travel' : intent_for_local_title(descriptor[:title])
    end

    def profile_for_period_descriptor(descriptor)
      period_travel_like_descriptor?(descriptor) ? 'travel' : profile_for_local_title(descriptor[:title])
    end

    def participant_names_from_text(text)
      normalized = normalize_japanese(text)
      names = []
      known_contact_names.each do |name|
        names << name if normalize_japanese(name).present? && normalized.include?(normalize_japanese(name))
      end
      normalized.scan(/(?<name>[^\s、。\/\d]+?(?:さん|くん|君|ちゃん)?|[a-zA-Z][a-zA-Z0-9_\-]{0,20})(?:と|との)(?=会議|定例|打ち合わせ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|チャット|会う|遊ぶ|相談|予定)/) do
        name = clean_participant_name(Regexp.last_match[:name].to_s)
        names << name if valid_participant_name?(name)
      end
      names.map(&:strip).reject(&:blank?).uniq.first(4)
    end

    def known_contact_names
      contacts = Array(context_value(:contacts)).filter_map do |contact|
        next unless contact.respond_to?(:to_h)
        attrs = contact.to_h
        (attrs[:display_name] || attrs['display_name'] || attrs[:name] || attrs['name']).to_s.strip.presence
      end
      friends = Array(context_value(:friends)).filter_map do |friend|
        next unless friend.respond_to?(:to_h)
        attrs = friend.to_h
        (attrs[:name] || attrs['name'] || attrs[:display_name] || attrs['display_name']).to_s.strip.presence
      end
      (contacts + friends).uniq.sort_by { |name| -normalize_japanese(name).length }
    end

    def clean_participant_name(value)
      normalize_japanese(value).gsub(/^(?:に|は|で|を|と|、|。)+/, '').gsub(/(?:さん|くん|君|ちゃん)$/, '').strip
    end

    def valid_participant_name?(name)
      return false if name.blank? || name.length > 18 || name.match?(/\A\d+\z/)
      !%w[会議 定例 飲み会 飲み 食事 旅行 予定 レビュー 通院 病院 午後 午前 今日 明日 明後日].include?(name)
    end

    def compose_local_event_title(activity_title, names)
      names = Array(names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      names.empty? ? clean_activity_title(activity_title) : "#{names.join('・')}と#{clean_activity_title(activity_title)}"
    end

    def activity_title_from_text(text, fallback_title: nil)
      explicit_title = explicit_activity_title_from_user_text(text)
      return explicit_title if explicit_title.present?

      subject_title = subject_study_activity_title_from_text(text)
      return subject_title if subject_title.present?

      source = remove_local_location_phrases(remove_participant_phrases(remove_date_time_phrases(text)))
      cleaned = clean_activity_title(source)
      return cleaned if cleaned.present? && cleaned.length <= 24 && !request_phrase_only?(cleaned) && !insufficient_activity_title?(cleaned)

      fallback_title.presence || local_title_from_text(text)
    end

    def explicit_activity_title_from_user_text(text)
      source = remove_local_location_phrases(remove_participant_phrases(remove_date_time_phrases(text)))
      title = clean_activity_title(source)
      return nil if insufficient_activity_title?(title)

      title
    end

    def insufficient_activity_title?(title)
      normalized = normalize_japanese(title)
      return true if normalized.blank?
      return true if normalized.match?(/\A(?:予定|空いてるところ|空き|ところ|さん|くん|ちゃん)\z/)
      return true if time_of_day_only_title?(normalized)
      return true if normalized.match?(/\A.+(?:さん|くん|ちゃん)\z/) && !normalized.match?(/会議|打ち合わせ|打合せ|ミーティング|面談|相談|電話|作業|学習|勉強|復習|予習|レビュー|確認/)

      false
    end

    def time_of_day_only_title?(title)
      normalize_japanese(title).match?(/\A(?:朝|朝イチ|朝一|午前|午前中|午後|昼|お昼|正午|夕方|放課後|夜|よる|今夜|今晩|深夜|未明)\z/)
    end

    def should_override_ai_title?(current_title, candidate_title)
      return false if candidate_title.blank? || insufficient_activity_title?(candidate_title)

      current = normalize_japanese(current_title)
      candidate = normalize_japanese(candidate_title)
      return true if current.blank?
      return true if generic_study_title?(current_title)
      return true if current == candidate
      return true if current.include?(candidate) || candidate.include?(current)
      return true if candidate_title.match?(/[A-Z]/) && current == normalize_japanese(candidate_title)

      false
    end

    def subject_study_activity_title_from_text(text)
      source = normalize_japanese_preserve_case(remove_date_time_phrases(text))

      match = source.match(/(?<title>[一-龥ぁ-んァ-ヶA-Za-z0-9_\-]+の(?:復習|予習|宿題|課題|勉強|学習|練習|確認|レビュー))/)
      return nil unless match

      title = clean_activity_title(match[:title])
      return nil if title.blank? || title == '予定'

      title
    end

    def preserve_user_title_case_in_object!(object, title)
      return object if title.blank?

      normalized_title = normalize_japanese(title)

      case object
      when Hash
        object.keys.each do |key|
          object[key] = preserve_user_title_case_in_object!(object[key], title)
        end
        object
      when Array
        object.map! { |item| preserve_user_title_case_in_object!(item, title) }
      when String
        preserve_user_title_case_in_string(object, title, normalized_title)
      else
        object
      end
    end

    def preserve_user_title_case_in_string(value, title, normalized_title = nil)
      original = value.to_s
      normalized = normalized_title.presence || normalize_japanese(title)
      return original if normalized.blank?

      original.gsub(normalized, title)
    end

    def skip_user_text_title_override?(response)
      return false unless response.respond_to?(:to_h)

      hash = response.to_h
      provider = (hash[:provider] || hash['provider']).to_s
      return true if provider.match?(/\Arails-local-(focus-work|existing-event-delete|existing-event-update|event-reminder|travel-assist)/)

      recommendation_list = Array(hash[:recommendations] || hash['recommendations'])
      recommendation_list.any? do |recommendation|
        next false unless recommendation.respond_to?(:to_h)

        kind = recommendation[:kind] || recommendation['kind']
        kind.to_s.match?(/\Aevent_(delete|update|reminder)\z/)
      end
    end

    def apply_user_text_title_overrides(response)
      return response if skip_user_text_title_override?(response)

      candidate_title = explicit_activity_title_from_user_text(@user_message)
      subject_title = subject_study_activity_title_from_text(@user_message)
      override_title = candidate_title.presence || subject_title
      return response if override_title.blank?
      return response unless response.respond_to?(:to_h)

      hash = response
      recommendations = hash[:recommendations] || hash['recommendations']
      recommendation_list = Array(recommendations)
      return response if recommendation_list.length > 1
      return response if recommendation_list.any? do |recommendation|
        next false unless recommendation.respond_to?(:to_h)

        payload = recommendation[:payload] || recommendation['payload']
        events = payload.respond_to?(:to_h) ? (payload[:events] || payload['events']) : nil
        Array(events).length > 1
      end

      recommendation_list.each do |recommendation|
        next unless recommendation.respond_to?(:to_h)

        current_title = recommendation[:title] || recommendation['title']
        payload = recommendation[:payload] || recommendation['payload']
        payload_title = payload.respond_to?(:to_h) ? (payload[:title] || payload['title']) : nil

        if should_override_ai_title?(current_title, override_title) || should_override_ai_title?(payload_title, override_title)
          write_hash_title(recommendation, override_title)
          write_hash_title(payload, override_title) if payload.respond_to?(:to_h)
        end
      end

      preserve_user_title_case_in_object!(hash, override_title)
      hash
    end

    def generic_study_title?(value)
      normalize_japanese(value).match?(/\A(?:復習|予習|宿題|課題|勉強|学習|練習|確認|レビュー|予定)\z/)
    end

    def write_hash_title(hash, title)
      return unless hash.respond_to?(:[]=)

      wrote = false
      if hash.respond_to?(:key?) && hash.key?('title')
        hash['title'] = title
        wrote = true
      end
      if hash.respond_to?(:key?) && hash.key?(:title)
        hash[:title] = title
        wrote = true
      end
      hash['title'] = title unless wrote
    end

    def remove_participant_phrases(text)
      preserved = normalize_japanese_preserve_case(text)
      known_contact_names.each do |name|
        normalized_name = normalize_japanese_preserve_case(name)
        next if normalized_name.blank?
        preserved = preserved.gsub(/#{Regexp.escape(normalized_name)}(?:さん|くん|君|ちゃん)?(?:と|との)/i, '')
      end
      preserved.gsub(/[^\s、。\/\d]+?(?:さん|くん|君|ちゃん)?(?:と|との)(?=会議|定例|打ち合わせ|打合せ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|チャット|会う|遊ぶ|相談|予定)/, '')
    end

    def remove_local_location_phrases(text)
      value = normalize_japanese_preserve_case(text).gsub(/\A[\s、。,.，．・:：;；]+/, '')
      location = extract_local_location(value)
      return value if location.blank?

      escaped = Regexp.escape(location)
      value.gsub(/\A\s*#{escaped}\s*(?:で|に|へ)\s*[、,]?\s*/, '')
    end

    def remove_date_time_phrases(text)
      remove_explicit_clock_phrases(text)
        .gsub(/(?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])(?:月|[\/\-])(?:3[01]|[12]\d|0?[1-9])日?\s*(?:から|〜|~|-)\s*(?:(?:\d{4})年)?(?:(?:1[0-2]|0?[1-9])(?:月|[\/\-]))?(?:3[01]|[12]\d|0?[1-9])日?(?:まで)?/, '')
        .gsub(/(?<!\d)(?:3[01]|[12]\d|0?[1-9])日\s*(?:から|〜|~|-)\s*(?:3[01]|[12]\d|0?[1-9])日?(?:まで)?/, '')
        .gsub(/(?:(?:再来週|来週|翌週|今週|次の)の?)?\s*[月火水木金土日](?:曜日|曜)?\s*(?:から|〜|~|-)\s*(?:(?:再来週|来週|翌週|今週|次の)の?)?\s*[月火水木金土日](?:曜日|曜)?(?:まで)?/, '')
        .gsub(/(?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])(?:月|[\/\-])(?:3[01]|[12]\d|0?[1-9])日?/, '')
        .gsub(/(?<!\d)(?:3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/, '')
        .gsub(/(?:\d+|[一二三四五六七八九十]+)(?:日|にち)後/, '')
        .gsub(/(?:再来月|来月|今月)の?最終[月火水木金土日](?:曜日|曜)?/, '')
        .gsub(/(?:(?:来月|翌月|今月)の?)?第[1-5一二三四五][月火水木金土日](?:曜日|曜)?/, '')
        .gsub(/(?:再来週|来週|翌週|今週|次の)?(?:の)?\s*[月火水木金土日](?:曜日|曜)/, '')
        .gsub(/(?:(?:再来週|来週|翌週|今週)の?)?(?:週末|末|土日)(?:で|に|から|まで)?/i, '')
        .gsub(/(今日|きょう|明日|あした|明後日|あさって|昨日|きのう|一昨日|おととい|再来週|来週|翌週|今週|再来月|来月|翌月|今月|月末|来月頭|月初|頭|gw中|gw明け|連休明け)/i, '')
        .gsub(/(終日|一日中|1日中|丸一日|まる一日|全日|all\s*day)(?:で|に|の)?/i, '')
        .gsub(/(?:から|〜|~|-)\s*-?\d{1,3}(?:\.\d+)?\s*時間\s*半/i, '')
        .gsub(/(?:から|〜|~|-)\s*-?\d{1,3}(?:\.\d+)?\s*時間/i, '')
        .gsub(/(?:から|〜|~|-)\s*-?\d{1,3}\s*分/i, '')
        .gsub(/-?\d{1,3}(?:\.\d+)?\s*時間\s*半/i, '')
        .gsub(/-?\d{1,3}(?:\.\d+)?\s*時間/i, '')
        .gsub(/-?\d{1,3}\s*分/i, '')
        .gsub(/(?:am|pm|朝イチ|朝一|午前中|午前|午後|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)?/i, '')
        .gsub(/朝\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)/, '')
    end

    def remove_explicit_clock_phrases(text)
      clock_scan = explicit_clock_scan(text, preserve_case: true)
      time_ranges = explicit_time_range_matches(clock_scan[:source], scan: clock_scan)
      range_spans = time_ranges.map do |range|
        range[:start_index]...range[:end_index]
      end
      cue_spans = time_ranges.flat_map { |range| Array(range[:cue_spans]) }
      token_spans = explicit_time_matches(clock_scan[:source], scan: clock_scan).map do |token|
        end_index = token[:end_index]
        if (suffix = clock_scan[:source][end_index...].to_s.match(/\A[ \t]*(?:から|以降|まで|〜|~|-|に|開始)/))
          end_index += suffix.end(0)
        end
        token[:start_index]...end_index
      end
      merged_spans = (range_spans + cue_spans + token_spans).sort_by(&:begin).each_with_object([]) do |span, merged|
        if merged.last && span.begin <= merged.last.end
          merged[-1] = merged.last.begin...[merged.last.end, span.end].max
        else
          merged << span
        end
      end

      value = clock_scan[:source].dup
      merged_spans.reverse_each do |span|
        value[span] = ''
      end
      value
    end

    def strip_request_action_suffix(value)
      value.to_s
        .gsub(/\s*(?:を)?(?:入れてください|入れて|入れる|いれてください|いれて|いれる|入れといて|いれといて|入れたい|いれたい|追加してください|追加して|追加|登録してください|登録して|登録|作ってください|作って|作る|確保してください|確保して|確保|お願いします|お願い|してください|して)\s*\z/i, '')
        .gsub(/\s*(?:予定)?(?:入れて|いれて|入れる|いれる)\s*\z/i, '')
    end

    def clean_activity_title(value)
      title = normalize_japanese_preserve_case(value).strip
      title = title.gsub(/(終日|一日中|1日中|丸一日|まる一日|全日|all\s*day)(?:で|に|の)?/i, '')
      title = title.gsub(/\A[\s、。,.，．・:：;；]+/, '')
      title = title.gsub(/\A(?:時|じ|分|間|半)(?:に|から|で)?/, '')
      title = title.gsub(/\A半(?=会議|打ち合わせ|打合せ|ミーティング|作業|学習|勉強|確認|レビュー|電話)/, '')
      title = title.gsub(/\A(?:から|まで|以降|の間|間で|間に)+/, '')
      title = title.gsub(/\A(?:am|pm|朝イチ|朝一|午前中|午前|午後|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)?/i, '')
      title = title.gsub(/\A朝\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)/, '')
      title = title.gsub(/\A(?:朝イチ|朝一|午前中|午前|午後|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午|朝)\z/, '')
      title = title.gsub(/^(に|は|で|を|と|の|から|間|半)+/, '')
      title = title.gsub(/\s*(を)?(入れてください|入れて|入れる|追加してください|追加して|追加|登録してください|登録して|登録|作ってください|作って|作る|確保してください|確保して|確保|お願いします|お願い|してください|して)\s*$/, '')
      title = title.gsub(/\s*(?:したい|やりたい)\s*$/, '')
      title = title.gsub(/\s*の(?:時間|予定)\s*$/, '')
      title = title.gsub(/\A(?:だけ|少しだけ|ちょっとだけ)\s*/, '')
      title = strip_request_action_suffix(title)
      title = title.gsub(/\s*(を|に|は|で|と|の)\s*$/, '')
      title = title.gsub(/\A[\s、。,.，．・:：;；]+|[\s、。,.，．・:：;；]+\z/, '').strip
      title.present? ? title : '予定'
    end

    def request_phrase_only?(value)
      normalize_japanese(value).match?(/\A(入れて|追加|お願い|お願いします|ください|して|作って|作る|確保して|確保)+\z/)
    end

    def clean_local_title(value)
      title = clean_activity_title(value)
      title.blank? || title.length > 18 || request_phrase_only?(title) ? local_title_from_text(title) : title
    end

    def local_title_from_text(text)
      normalized = normalize_japanese(text)
      return focus_work_title_from_text(normalized) if focus_work_request?(normalized)
      return 'ストレッチ' if normalized.match?(/ストレッチ|体操/)
      return '休憩' if normalized.include?('休憩')
      return 'チャット' if normalized.include?('チャット')
      return '電話' if normalized.match?(/電話|tel|コール|call/)
      return '会う予定' if normalized.match?(/会う|会って|遊ぶ/)
      return '学校の準備' if normalized.include?('学校の準備')
      return '定例' if normalized.include?('定例')
      return '飲み会' if normalized.include?('飲み会') || normalized.include?('飲み')
      return '食事' if normalized.match?(/食事|ご飯|ごはん|ランチ|ディナー/)
      return '旅行' if normalized.include?('旅行')
      return '出張' if normalized.include?('出張')
      return '滞在' if normalized.include?('滞在')
      return '観光' if normalized.include?('観光')
      return '宿泊' if normalized.include?('宿泊')
      return '会議' if normalized.match?(/会議|ミーティング|打ち合わせ/)
      return 'レビュー' if normalized.include?('レビュー')
      return '通院' if normalized.match?(/通院|病院/)
      return '支払い' if normalized.include?('支払い')
      '予定'
    end

    def schedule_summary_request?(text)
      normalized = normalize_japanese(text)
      return false if schedule_organization_request?(normalized)

      clauses = split_event_clauses(normalized)
      explicit_summary_indexes = clauses.each_index.select do |index|
        explicit_schedule_summary_clause?(clauses[index])
      end
      permissive_adjacent_summary_pairs = clauses.each_cons(2).with_index.filter_map do |(target_clause, control_clause), index|
        if generic_schedule_summary_target_clause?(target_clause) &&
           schedule_summary_control_only_clause?(control_clause)
          [index, index + 1]
        end
      end
      strong_adjacent_summary_pairs = clauses.each_cons(2).with_index.filter_map do |(target_clause, control_clause), index|
        if strong_schedule_summary_target_clause?(target_clause) &&
           strong_schedule_summary_control_only_clause?(control_clause)
          [index, index + 1]
        end
      end
      adjacent_summary_pairs = (permissive_adjacent_summary_pairs + strong_adjacent_summary_pairs).uniq

      candidate_items = weekday_multi_candidate_items(clauses)
      candidate_shape = weekday_multi_candidate_items_form_shape?(candidate_items)
      if candidate_shape
        candidate_indexes = candidate_items.map { |item| item[:index] }
        return true if explicit_summary_indexes.any? { |index| !candidate_indexes.include?(index) }
        return true if adjacent_summary_pairs.any? { |pair| (pair & candidate_indexes).empty? }
        return true if explicit_summary_indexes.any? do |index|
          next false unless strong_explicit_schedule_summary_clause?(clauses[index])

          remaining_items = candidate_items.reject { |item| item[:index] == index }
          weekday_multi_candidate_items_form_shape?(remaining_items)
        end
        return true if strong_adjacent_summary_pairs.any? do |pair|
          remaining_items = candidate_items.reject { |item| pair.include?(item[:index]) }
          weekday_multi_candidate_items_form_shape?(remaining_items)
        end

        return false
      end

      explicit_summary_indexes.any? || adjacent_summary_pairs.any?
    end

    def explicit_schedule_summary_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip
      return false if normalized.blank?

      target_match = normalized.match(
        /(?:\A|[の \t　、,])(?:予定|スケジュール)[ \t]*(?:(?:を|は|で|について)[ \t]*(?:[、,][ \t]*)?)?(?<control>.+)\z/
      )
      return true if target_match && schedule_summary_control_only_clause?(target_match[:control])

      relative_match = normalized.match(/\A(?:今日|明日|明後日|今週|来週)(?:は|で)?(?<control>.+)\z/)
      return true if relative_match && schedule_summary_control_only_clause?(relative_match[:control])

      normalized.match?(/\A忙しい日(?:を)?(?:教えて|確認して)?(?:ください|下さい)?\z/)
    end

    def strong_explicit_schedule_summary_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip
      target_match = schedule_summary_target_activity_text(normalized).match(
        /\A(?:予定|スケジュール)[ \t]*(?:を|は|で|について)[ \t]*(?<control>.+)\z/
      )

      target_match && strong_schedule_summary_control_only_clause?(target_match[:control])
    end

    def strong_schedule_summary_target_clause?(clause)
      schedule_summary_target_activity_text(clause).match?(
        /\A(?:予定|スケジュール)[ \t]*(?:を|は|で|について)\z/
      )
    end

    def schedule_summary_target_activity_text(clause)
      remove_date_time_phrases(normalize_japanese(clause))
        .sub(/\A[ \t　、,]*(?:(?:と|の|に|は|で)[ \t　、,]*)+/, '')
        .sub(/[。.！!？?]\z/, '')
        .strip
    end

    def strong_schedule_summary_control_only_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip

      normalized.match?(
        /\A(?:
          まとめて(?:教えて)? |
          要約して |
          確認して |
          チェックして |
          教えて |
          何がある |
          注意(?:点)?(?:を)?(?:教えて|確認して) |
          忙しい日(?:を)?(?:教えて|確認して) |
          多い日(?:を)?(?:教えて|確認して) |
          詰まっている日(?:を)?(?:教えて|確認して) |
          空き状況(?:を)?(?:教えて|確認して)
        )(?:ください|下さい|お願いします)?\z/x
      )
    end

    def generic_schedule_summary_target_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip
      return false if normalized.blank? || explicit_time_present?(normalized)

      schedule_summary_target_activity_text(normalized).match?(
        /\A(?:予定|スケジュール)(?:を|は|で|について)?\z/
      )
    end

    def schedule_summary_control_only_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip

      normalized.match?(
        /\A(?:
          まとめ(?:て)?(?:教えて)? |
          要約(?:して)? |
          確認(?:して)? |
          チェック(?:して)? |
          教えて |
          何がある |
          注意(?:点)?(?:を)?(?:教えて|確認して)? |
          忙しい日(?:を)?(?:教えて|確認して)? |
          多い日(?:を)?(?:教えて|確認して)? |
          詰まっている日(?:を)?(?:教えて|確認して)? |
          空き状況(?:を)?(?:教えて|確認して)?
        )(?:ください|下さい|お願いします)?\z/x
      )
    end

    def schedule_summary_range(text)
      now = context_now
      normalized = normalize_japanese(text)

      if normalized.include?('明日') || normalized.include?('あした')
        date = now.to_date + 1
        return ['明日', date, date]
      end

      if normalized.include?('明後日') || normalized.include?('あさって')
        date = now.to_date + 2
        return ['明後日', date, date]
      end

      if normalized.include?('来週')
        start_date = beginning_of_week(now.to_date) + 7
        return ['来週', start_date, start_date + 6]
      end

      if normalized.include?('今週') || normalized.include?('忙しい日')
        start_date = beginning_of_week(now.to_date)
        return ['今週', start_date, start_date + 6]
      end

      if (date = first_local_date_from_text(text))
        return [date == now.to_date ? '今日' : date.strftime('%-m/%-d'), date, date]
      end

      ['今日', now.to_date, now.to_date]
    end

    def schedule_summary_message(period_label, events, range_start, range_end, include_attention: false)
      if events.empty?
        return "#{period_label}の予定はありません。"
      end

      lines = []
      lines << "#{period_label}の予定は#{events.length}件あります。"
      lines << ''
      grouped = events.group_by { |event| event_date_for_group(event) || range_start }
      grouped.sort_by { |date, _| date }.each do |date, rows|
        lines << date.strftime('%-m/%-d') if range_start != range_end
        rows.sort_by { |event| event_time_for_sort(event) || app_time_zone.local(date.year, date.month, date.day, 23, 59, 0) }.each do |event|
          lines << "- #{format_event_for_summary(event)}"
        end
      end

      attention = schedule_attention_line(events, include_attention: include_attention)
      lines << '' << attention if attention.present?
      lines.join("\n")
    end

    def busy_days_message(period_label, events, range_start, range_end)
      if events.empty?
        return "#{period_label}の予定はありません。忙しい日はありません。"
      end

      counts = events.group_by { |event| event_date_for_group(event) || range_start }.transform_values(&:length)
      max_count = counts.values.max || 0
      busy = counts.select { |_date, count| count == max_count && count.positive? }.keys.sort
      lines = []
      lines << "#{period_label}で一番忙しい日は#{busy.map { |date| date.strftime('%-m/%-d') }.join('、')}です。"
      lines << "予定数は#{max_count}件です。"
      lines << ''
      counts.sort_by { |date, _count| date }.each do |date, count|
        lines << "- #{date.strftime('%-m/%-d')}: #{count}件"
      end
      lines.join("\n")
    end

    def schedule_attention_line(events, include_attention: false)
      all_day_count = events.count { |event| ActiveModel::Type::Boolean.new.cast(event.to_h[:all_day] || event.to_h['all_day']) }
      timed_count = events.length - all_day_count
      return "終日予定が#{all_day_count}件あります。時間付き予定の前後に余裕を確認してください。" if all_day_count.positive? && timed_count.positive?
      return '予定が多めです。移動や準備時間を確保してください。' if events.length >= 4
      return '注意点は大きくありません。必要なら空き時間候補も出せます。' if include_attention

      nil
    end

    def format_event_for_summary(event)
      attrs = event.to_h
      title = attrs[:title] || attrs['title'] || '予定'
      all_day = ActiveModel::Type::Boolean.new.cast(attrs[:all_day] || attrs['all_day'])
      return "終日: #{title}" if all_day

      start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])
      end_at = parse_context_time(attrs[:end_at] || attrs['end_at'])
      return title.to_s unless start_at && end_at

      "#{start_at.strftime('%H:%M')} - #{end_at.strftime('%H:%M')} #{title}"
    end

    def event_date_for_group(event)
      attrs = event.to_h
      parse_context_time(attrs[:start_at] || attrs['start_at'])&.to_date
    end

    def event_time_for_sort(event)
      attrs = event.to_h
      parse_context_time(attrs[:start_at] || attrs['start_at'])
    end

    def personal_events_between_dates(range_start, range_end)
      start_time = app_time_zone.local(range_start.year, range_start.month, range_start.day, 0, 0, 0)
      end_time = app_time_zone.local(range_end.year, range_end.month, range_end.day, 23, 59, 59)

      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)
        attrs = event.to_h
        start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])
        end_at = parse_context_time(attrs[:end_at] || attrs['end_at'])
        start_at && end_at && end_at > start_time && start_at <= end_time
      end
    end

    def open_slot_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/空き|空いて|空い?ている|空いてる|空き時間|空いている時間/)
      return false if normalized.match?(/まとめ|要約|確認|忙しい日/)
      true
    end

    def reminder_request?(text)
      normalize_japanese(text).match?(/リマインダー|通知|知らせて|アラート|remind/i)
    end

    def reminder_minutes_before(text)
      normalized = normalize_japanese(text)
      return Regexp.last_match[:value].to_i * 60 if normalized.match(/(?<value>\d{1,2})\s*時間前/)
      return Regexp.last_match[:value].to_i if normalized.match(/(?<value>\d{1,3})\s*分前/)
      return 60 if normalized.match?(/1時間前|一時間前/)
      return 15 if normalized.match?(/少し前/)
      30
    end

    def reminder_clarification_response(message, matched_count)
      {
        assistant_message: message,
        recommendations: [],
        provider: 'rails-local-event-reminder-clarification-v1',
        policy_run: local_policy_run('rails-local-event-reminder-clarification-v1', { matched_count: matched_count }),
        tool_invocations: []
      }
    end

    def existing_event_update_payload(event, text)
      attrs = event.to_h
      current_start = parse_context_time(attrs[:start_at] || attrs['start_at'])
      current_end = parse_context_time(attrs[:end_at] || attrs['end_at'])
      return nil unless current_start && current_end

      timing = parse_local_schedule_timing(
        text,
        default_duration: ((current_end - current_start) / 60).round
      )
      start_minute = timing[:start_minute]
      parsed_duration = timing[:duration_minutes]
      new_date = first_local_date_from_text(text) || current_start.to_date
      return nil unless new_date || start_minute

      all_day = ActiveModel::Type::Boolean.new.cast(attrs[:all_day] || attrs['all_day'])
      duration = parsed_duration || ((current_end - current_start) / 60).round

      if all_day && start_minute.blank?
        start_at = app_time_zone.local(new_date.year, new_date.month, new_date.day, 0, 0, 0)
        end_at = start_at + [(current_end.to_date - current_start.to_date).to_i, 1].max.days
        return {
          'start_at' => start_at.iso8601,
          'end_at' => end_at.iso8601,
          'all_day' => true
        }
      end

      start_minute ||= current_start.hour * 60 + current_start.min
      start_at = local_time_at_minute(new_date, start_minute)
      return nil unless start_at

      end_at = if timing[:end_minute]
                 local_time_at_minute(new_date, timing[:end_minute])
               else
                 start_at + duration.minutes
               end
      return nil unless end_at && end_at > start_at

      {
        'start_at' => start_at.iso8601,
        'end_at' => end_at.iso8601,
        'all_day' => false
      }
    end

    def format_datetime_range_for_message(start_value, end_value, all_day)
      start_at = parse_context_time(start_value)
      end_at = parse_context_time(end_value)
      return '' unless start_at && end_at

      if ActiveModel::Type::Boolean.new.cast(all_day)
        inclusive_end = (end_at.to_date - 1)
        return start_at.strftime('%-m/%-d 終日') if inclusive_end <= start_at.to_date
        return "#{start_at.strftime('%-m/%-d')}〜#{inclusive_end.strftime('%-m/%-d')} 終日"
      end

      "#{start_at.strftime('%-m/%-d %H:%M')} - #{end_at.strftime('%H:%M')}"
    end

    def parse_context_time(value)
      return nil if value.blank?
      app_time_zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def schedule_organization_request?(text)
      normalized = normalize_japanese(text)
      clauses = split_event_clauses(normalized)

      clauses.any? { |clause| explicit_schedule_organization_clause?(clause) }
    end

    def explicit_schedule_organization_clause?(clause)
      normalized = normalize_japanese(clause).sub(/[。.！!？?]\z/, '').strip
      return false if normalized.blank?

      state_request = normalized.match?(
        /(?:予定|スケジュール).*?(?:が|は)?(?:多すぎる|多い|詰まっている|詰まってる|パンパン)(?:\z|(?:ので|から|だから|ため|て).*)/
      )
      return true if state_request && schedule_organization_action_suffix?(normalized)
      return true if normalized.match?(/(?:予定|スケジュール).*?(?:が|は)?(?:多すぎる|多い|詰まっている|詰まってる|パンパン)\z/)

      target_match = normalized.match(
        /(?:予定|スケジュール)[ \t　]*(?:を|は|について|の)?[ \t　]*(?<action>.+)\z/
      )
      return true if target_match && schedule_organization_action_only?(target_match[:action])

      normalized.match?(/(?:\A|[ \t　、,])(?:整理したい|見直したい|棚卸ししたい)\z/)
    end

    def schedule_organization_action_suffix?(value)
      normalized = normalize_japanese(value).strip
      action = normalized.match(
        /(?<action>
          整理(?:したい|して(?:ください|下さい)?|する) |
          見直(?:したい|して(?:ください|下さい)?|す) |
          棚卸し(?:したい|して(?:ください|下さい)?|する) |
          減ら(?:したい|して(?:ください|下さい)?|す) |
          削(?:りたい|って(?:ください|下さい)?|る) |
          移動(?:したい|して(?:ください|下さい)?|する) |
          (?:整理|見直し|棚卸し|削減|移動)(?:を)?(?:したい|して(?:ください|下さい)?|する)
        )\z/x
      )

      action.present?
    end

    def schedule_organization_action_only?(value)
      schedule_organization_action_suffix?(value) &&
        normalize_japanese(value).match?(
          /\A(?:
            整理(?:したい|して(?:ください|下さい)?|する) |
            見直(?:したい|して(?:ください|下さい)?|す) |
            棚卸し(?:したい|して(?:ください|下さい)?|する) |
            減ら(?:したい|して(?:ください|下さい)?|す) |
            削(?:りたい|って(?:ください|下さい)?|る) |
            移動(?:したい|して(?:ください|下さい)?|する) |
            (?:整理|見直し|棚卸し|削減|移動)(?:を)?(?:したい|して(?:ください|下さい)?|する)
          )\z/x
        )
    end

    def schedule_organization_range(text)
      now = context_now.to_date

      if normalize_japanese(text).include?('来週')
        start_date = now + ((8 - now.wday) % 7)
        return ['来週', start_date, start_date + 6]
      end

      if normalize_japanese(text).include?('今週')
        start_date = now - ((now.wday + 6) % 7)
        return ['今週', start_date, start_date + 6]
      end

      ['直近1週間', now, now + 6]
    end

    def personal_events_between_dates(start_date, end_date)
      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)

        attrs = event.to_h
        start_at = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
        start_at && start_at.to_date >= start_date && start_at.to_date <= end_date
      end
    end

    def focus_work_request?(text)
      normalize_japanese(text).match?(/集中作業|集中して|深い作業|ディープワーク|focus|作業時間|作業の時間|資料作成|資料を作|メモ整理|レビュー時間|課題時間|課題|宿題|復習|勉強|学習/)
    end

    def focus_work_title_from_text(text)
      preserved_subject_title = subject_study_activity_title_from_text(text)
      return preserved_subject_title if preserved_subject_title.present? && preserved_subject_title.match?(/[A-Z]/)

      normalized = normalize_japanese(text)
      return '資料作成' if normalized.match?(/資料作成|資料を作/)
      return 'メモ整理' if normalized.include?('メモ整理')
      return 'レビュー時間' if normalized.include?('レビュー時間')
      return '課題時間' if normalized.match?(/課題|宿題/)
      return '復習' if normalized.include?('復習')
      return '勉強' if normalized.match?(/勉強|学習/)

      '集中作業'
    end

    def event_mutation_or_reference_request?(text)
      normalized = normalize_japanese(text)
      existing_event_delete_request?(normalized) ||
        reminder_request?(normalized) ||
        normalized.match?(/変更|移動|ずらして|リスケ|延期|前倒し|削除|消して|消す|消したい|キャンセル|取り消し|通知|リマインダー/)
    end

    def recurrence_request?(text)
      normalize_japanese(text).match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)
    end

    def negative_reminder_offset_match(text)
      normalized = normalize_japanese(text)
      match = normalized.match(/[-−]\s*(?<value>\d{1,3}(?:\.\d+)?)\s*(?<unit>分|時間)\s*前/)
      return nil unless match

      "-#{match[:value]}#{match[:unit]}前"
    end

    def explicit_reminder_offset_present?(text)
      normalized = normalize_japanese(text)
      normalized.match?(/(?<![-−])\d{1,3}\s*分前/) ||
        normalized.match?(/(?<![-−])\d{1,2}\s*時間前/) ||
        normalized.match?(/一時間前|少し前/)
    end

    def explicit_date_weekday_mismatch(text)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<year>\d{4})年(?<month>1[0-2]|0?[1-9])月(?<day>3[01]|[12]\d|0?[1-9])日?\s*(?:は|に)?\s*(?<weekday>[月火水木金土日])(?:曜日|曜)?/)
      return nil unless match

      date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
      requested = WEEKDAY_MAP[match[:weekday]]
      return nil if requested.nil? || date.wday == requested

      {
        date_label: date.strftime('%Y年%-m月%-d日'),
        requested_weekday: WEEKDAY_LABELS[requested],
        actual_weekday: WEEKDAY_LABELS[date.wday]
      }
    rescue StandardError
      nil
    end

    def morning_night_conflict_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/朝\s*夜|朝夜|夜\s*朝|夜朝/)
      return false if event_mutation_or_reference_request?(normalized)

      first_local_date_from_text(normalized).present? || normalized.match?(/入れて|追加|登録|作って|予定|勉強|学習|会議|作業/)
    end

    def vague_open_slot_without_details?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/空いてるところ|空いているところ|空き時間|空き|空いて/)
      return false if focus_work_request?(normalized)
      return false if explicit_time_present?(normalized)
      return false if explicit_duration_minutes(normalized).present?

      title = clean_activity_title(remove_date_time_phrases(normalized).gsub(/(?:の)?(?:空いてるところ|空いているところ|空き時間|空き|空いて)(?:で|に)?/, ''))
      title.blank? || title == '予定' || insufficient_activity_title?(title)
    end

    def date_only_schedule_request?(text)
      normalized = normalize_japanese(text)
      return false unless first_local_date_from_text(normalized)
      return false if explicit_time_present?(normalized) || period_window_hint?(normalized)
      return false if explicit_duration_minutes(normalized).present?

      title = clean_activity_title(remove_date_time_phrases(normalized))
      title.blank? || title == '予定' || request_phrase_only?(title)
    end

    def date_person_only_schedule_request?(text)
      normalized = normalize_japanese(text)
      return false unless first_local_date_from_text(normalized)
      return false if explicit_time_present?(normalized) || period_window_hint?(normalized) || explicit_all_day_request?(normalized)

      rest = clean_activity_title(remove_date_time_phrases(normalized))
      return false if known_activity_title?(rest)
      return false if location_or_movement_activity_title?(rest)

      rest.match?(/\A[一-龥ぁ-んァ-ヶA-Za-z0-9_\-]{1,18}(?:さん|くん|君|ちゃん)\z/) ||
        known_contact_names.any? { |name| normalize_japanese(name) == normalize_japanese(rest) }
    end

    def location_or_movement_activity_title?(title)
      normalized = normalize_japanese(title)
      normalized.match?(/(?:に|へ)(?:行く|行き|向かう|移動|帰る|帰省|戻る)|(?:帰る|帰省|戻る)\z/)
    end

    def known_activity_title?(title)
      normalize_japanese(title).match?(/会議|打ち合わせ|打合せ|ミーティング|電話|作業|資料|メモ|確認|レビュー|飲み|食事|旅行|出張|滞在|観光|宿泊|帰省|休み|休暇|勉強|学習|課題|チャット|営業|定例|会う|面談|相談|挨拶|掃除|買い物|読書|洗濯|散歩|運動|通院|病院|ランチ|ディナー/)
    end

    def weekend_period_request?(text)
      normalize_japanese(text).match?(/土日|週末/)
    end

    def remove_weekend_period_phrases(text)
      normalize_japanese_preserve_case(text)
        .gsub(/(?:(?:再来週|来週|翌週|今週)の?)?(?:週末|末|土日)(?:で|に|から|まで)?/, '')
        .gsub(/\A\s*(?:の|を|に|で)\s*/, '')
        .strip
    end

    def weekend_start_date_for_text(text)
      normalized = normalize_japanese(text)
      today = context_now.to_date
      if normalized.include?('再来週')
        week_start = beginning_of_week(today) + 14
        return week_start + ((6 - week_start.wday) % 7)
      end
      if normalized.match?(/来週|翌週/)
        week_start = beginning_of_week(today) + 7
        return week_start + ((6 - week_start.wday) % 7)
      end
      if normalized.include?('今週')
        week_start = beginning_of_week(today)
        saturday = week_start + ((6 - week_start.wday) % 7)
        return saturday >= today ? saturday : saturday + 7
      end

      next_weekday_on_or_after(today, 6)
    end

    def multi_intent_schedule_request?(text, clauses: nil)
      normalized = normalize_japanese(text)
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)

      clauses ||= schedule_event_clauses(normalized)
      clauses.length >= 2 && clauses.any? { |clause| explicit_time_present?(clause) }
    end

    def parse_multi_explicit_event_clause(original_clause, shared_date, title_source: original_clause)
      original_descriptor = local_event_descriptor(original_clause)
      title_descriptor = multi_event_title_descriptor(title_source)
      title = clean_activity_title(title_descriptor[:activity_title].presence || title_descriptor[:title])
      timing = parse_local_schedule_timing(original_clause, default_duration: 60)
      {
        clause: original_clause,
        date: first_local_date_from_text(original_clause) || shared_date,
        title: title,
        start_minute: timing[:start_minute],
        end_minute: timing[:end_minute],
        duration_minutes: timing[:duration_minutes] || 60,
        time_present: explicit_time_present?(original_clause),
        contact_name: original_descriptor[:contact_name],
        participant_names: original_descriptor[:participant_names],
        location: original_descriptor[:location],
        buffer_minutes: original_descriptor[:buffer_minutes]
      }
    end

    def explicit_timed_schedule_add_request?(text, clauses: nil)
      normalized = normalize_japanese(text)
      return false if event_mutation_or_reference_request?(normalized)
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return false if explicit_all_day_request?(normalized)
      return false if multi_intent_schedule_request?(normalized, clauses: clauses)

      first_local_date_from_text(normalized).present? && explicit_time_present?(normalized)
    end

    def conflicting_events(events, start_at, end_at)
      Array(events).select do |event|
        s, e = event_time_range(event)
        s && e && e > start_at && s < end_at
      end
    end

    def event_time_range(event)
      return [nil, nil] unless event.respond_to?(:to_h)

      attrs = event.to_h
      s = parse_context_time(attrs[:start_at] || attrs['start_at'])
      e = parse_context_time(attrs[:end_at] || attrs['end_at'])
      [s, e]
    end

    def event_title(event)
      attrs = event.respond_to?(:to_h) ? event.to_h : {}
      attrs[:title] || attrs['title'] || '予定'
    end

    def next_available_event_after_conflict(date:, duration:, conflicts:, title:, descriptor:)
      latest_end = conflicts.filter_map { |event| event_time_range(event).last }.max
      return nil unless latest_end && latest_end.to_date == date

      minute = round_up_to_interval(latest_end.hour * 60 + latest_end.min, 30)
      minute = [minute, 6 * 60].max
      latest_start = 22 * 60 - duration

      while minute <= latest_start
        start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
        end_at = start_at + duration.minutes
        if start_at > context_now && !conflicts_with_events?(context_value(:personal_events), start_at, end_at)
          return local_event_hash(
            title: title,
            start_at: start_at,
            end_at: end_at,
            all_day: false,
            color: color_for_local_title(title),
            category: category_for_local_title(title),
            intent: intent_for_local_title(title),
            schedule_profile: profile_for_local_title(title),
            reason: '指定時刻が既存予定と重なったため、同じ日の代替候補を作成しました。',
            contact_name: descriptor[:contact_name],
            participant_names: descriptor[:participant_names],
            location: descriptor[:location],
            buffer_minutes: descriptor[:buffer_minutes]
          )
        end
        minute += 30
      end

      nil
    end

    def first_available_start_minute_for_date(date:, duration:, text:, title:, participant_names: [], buffer_minutes: nil)
      preferred = default_start_minute_for_text(text, title)
      window_start, window_end = preferred_minute_window(text)
      window_start = [window_start, preferred].min
      window_end = [window_end, preferred + duration.to_i, 22 * 60].max
      latest_start = window_end - duration.to_i
      minute = [[preferred, window_start].max, latest_start].min

      while minute <= latest_start
        start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
        end_at = start_at + duration.to_i.minutes
        if start_at > context_now && free_for_all?(
          start_at,
          end_at,
          participant_names: participant_names,
          buffer_minutes: buffer_minutes.to_i
        )
          return minute
        end

        minute += 30
      end

      nil
    end

    def round_up_to_interval(minute, interval)
      ((minute.to_i + interval - 1) / interval) * interval
    end

    def between_existing_events_request?(text)
      normalized = normalize_japanese(text)
      normalized.match?(/予定.+と.+予定.+の間/) ||
        normalized.match?(/(?:予定|イベント|会議|授業|部活).+の間に.*休憩/) ||
        normalized.match?(/休憩.*(?:予定|イベント|会議|授業|部活).+間/) ||
        normalized.match?(/.+と.+の間に.*休憩/)
    end

    def ambiguous_schedule_request?(text)
      normalized = normalize_japanese(text)
      return false if schedule_organization_request?(normalized)
      return false if between_existing_events_request?(normalized)
      return false if normalized.match?(/空き|空いて|忙しくない|都合|候補|いつ|できれば|無理なら/)
      return false if normalized.match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)

      return true if normalized.match?(/\A(?:打ち合わせ|打合せ|会議|ミーティング|調整|相談)\z/)
      return true if normalized.match?(/\A.{1,18}さんと(?:調整して|相談して|打ち合わせ|打合せ)\z/) && !explicit_time_present?(normalized) && first_local_date_from_text(normalized).nil?
      return true if normalized.match?(/\A(?:午前|午後|夕方|放課後|夜|昼)(?:から|〜|~|-).*(?:の間|間で)\z/)

      return false if explicit_time_present?(normalized)
      return false if first_local_date_from_text(normalized)
      return false if target_weekdays(normalized).any?
      return false if normalized.match?(/\d+\s*(?:分|時間)|午前|午後|朝|昼|夕方|放課後|夜|今夜|今晩|深夜|未明/)

      normalized.match?(/\A\s*(?:予定を入れたい|予定を入れて|予定を作りたい|いい感じに調整して|調整して)\s*\z/) ||
        normalized.match?(/友(?:達|人).*予定.*(?:いい感じ|調整)/) ||
        normalized.match?(/何か.*予定|予定.*何か/)
    end

    def generic_schedule_request?(text)
      normalized = normalize_japanese(text).gsub(/[。.!！?？]\z/, '').sub(/(?:です|ます)\z/, '').strip
      return false if event_mutation_or_reference_request?(normalized)
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return false if first_local_date_from_text(normalized)
      return false if explicit_time_present?(normalized) || period_window_hint?(normalized)
      return false if explicit_duration_minutes(normalized).present? || explicit_all_day_request?(normalized)

      normalized.match?(/\A(?:予定(?:を)?(?:入れたい|入れて|追加したい|追加して|登録したい|登録して|作りたい)?|何か(?:予定を?)?(?:入れたい|入れて|追加したい|追加して|登録したい|登録して)|追加したい|登録したい)\z/)
    end

    def past_datetime_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/昨日|きのう|一昨日|おととい|先週/)
      return false if normalized.match?(/削除|消して|キャンセル|取り消し|変更|移動|ずらして|リスケ|整理|見直/)

      normalized.match?(/入れて|入れる|作って|作る|追加|登録|確保|予定/)
    end

    def invalid_explicit_date_match(text)
      normalized = normalize_japanese(text)
      now = context_now
      duration_ranges = []
      normalized.to_enum(:scan, SIGNED_OR_UNSIGNED_DURATION_EXPRESSION_PATTERN).each do
        match = Regexp.last_match
        start_byte_index, end_byte_index = match.byteoffset(0)
        duration_ranges << (start_byte_index...end_byte_index)
      end
      duration_index = 0
      numbered_list_markers = nil

      normalized.to_enum(:scan, EXPLICIT_DATE_COMPONENT_PATTERN).each do
        match = Regexp.last_match
        date_start_byte_index, date_end_byte_index = match.byteoffset(0)
        while (duration_range = duration_ranges[duration_index]) &&
              duration_range.end <= date_start_byte_index
          duration_index += 1
        end
        duration_range = duration_ranges[duration_index]

        next if duration_range &&
                date_start_byte_index >= duration_range.begin &&
                date_end_byte_index <= duration_range.end
        next if date_match_fragment_of_time_range?(normalized, match)
        numbered_list_markers ||= list_item_marker_candidates(normalized)
        next if date_match_fragment_of_numbered_list_marker?(normalized, match, numbered_list_markers)
        next if date_match_embedded_in_numeric_title?(normalized, match)

        month = match[:month].to_i
        day = match[:day].to_i
        year = match[:year].present? ? match[:year].to_i : now.year
        next if month.between?(1, 12) && Date.valid_date?(year, month, day)

        return { raw: match[0], year: year, month: month, day: day }
      end

      nil
    end

    def date_match_embedded_in_numeric_title?(text, match)
      date_syntax_match_embedded_in_numeric_title?(text, match)
    end

    def date_match_fragment_of_time_range?(text, match)
      raw = match[0].to_s
      return false unless raw.match?(/[\-~〜]/)

      before = text[[match.begin(0) - 3, 0].max...match.begin(0)].to_s
      after = text[match.end(0)...[match.end(0) + 3, text.length].min].to_s
      before.match?(/[:：]\d{0,2}\z/) || after.match?(/\A[:：]\d{0,2}/)
    end

    def date_match_fragment_of_numbered_list_marker?(text, match, markers)
      return false unless markers.length >= 2

      first_marker_index = markers.each_index.find do |index|
        skipped_prefix = markers[0...index]
        skipped_prefix.each_with_index.all? do |marker, prefix_index|
          numeric_title_marker_candidate?(text, marker, markers[prefix_index + 1])
        end && numbered_list_candidate_start?(text, markers[index])
      end
      return false unless first_marker_index

      markers[first_marker_index..].any? do |marker|
        marker[:number_start_index] == match.begin(0) && marker[:end_index] <= match.end(0)
      end
    end

    def invalid_duration_match(text)
      clock_scan = explicit_clock_scan(text)
      normalized = text_outside_clock_matches(
        clock_scan[:source],
        explicit_time_matches(clock_scan[:source], scan: clock_scan)
      )

      if (negative_duration = negative_duration_expression_match(normalized))
        return { raw: negative_duration[0] }
      end

      patterns = [
        /(?:から|〜|~)\s*0+(?:\.0+)?\s*(?:分|時間)?(?![\d:：時])/,
        /(?<![\d.])0+(?:\.0+)?[ \t　]*(?:分|時間)(?![\d.後])/
      ]

      patterns.each do |pattern|
        match = normalized.match(pattern)
        return { raw: match[0] } if match
      end

      nil
    end

    def explicit_start_datetime_from_text(text)
      date = first_local_date_from_text(text)
      return nil unless date

      start_minute = parse_local_time_and_duration(text, default_duration: 30).first
      return nil unless start_minute

      app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
    end

    def invalid_explicit_time_match(text)
      explicit_clock_scan(text)[:tokens].find { |token| !token[:valid] }
    end

    def explicit_time_present?(text)
      explicit_clock_scan(text)[:tokens].any?
    end

    def explicit_time_matches(text, scan: nil)
      (scan || explicit_clock_scan(text))[:tokens].select { |token| token[:valid] }
    end

    def explicit_clock_scan(text, preserve_case: false)
      source = preserve_case ? normalize_japanese_preserve_case(text) : normalize_japanese(text)
      tokens = []

      source.to_enum(:scan, CLOCK_TOKEN_PATTERN).each do
        match = Regexp.last_match
        next unless explicit_clock_token_context_valid?(source, match)

        hour_source = match[:colon_hour] || match[:arabic_hour] || match[:kanji_hour]
        minute_source = match[:colon_minute] ||
                        match[:arabic_numeric_minute] ||
                        match[:arabic_numeric_minute_without_unit] ||
                        match[:arabic_kanji_minute] ||
                        match[:kanji_numeric_minute] ||
                        match[:kanji_kanji_minute]
        unadjusted_hour = japanese_integer(hour_source)
        minute = if match[:arabic_half] || match[:kanji_half]
                   30
                 elsif minute_source
                   japanese_integer(minute_source)
                 else
                   0
                 end
        hour = unadjusted_hour.nil? ? nil : adjust_hour_for_period(unadjusted_hour, match[:period])

        tokens << {
          raw: match[0],
          hour: hour,
          minute: minute,
          period: match[:period],
          unadjusted_hour: unadjusted_hour,
          start_index: match.begin(0),
          end_index: match.end(0),
          valid: hour.is_a?(Integer) && minute.is_a?(Integer) && valid_clock_time?(hour, minute)
        }
      end

      { source: source, tokens: tokens }
    end

    def explicit_clock_token_context_valid?(source, match)
      return true unless match[:arabic_hour]
      return true if match[:period].present?
      return true if match[:arabic_half] || match[:arabic_numeric_minute] ||
                     match[:arabic_numeric_minute_without_unit] || match[:arabic_kanji_minute]

      suffix = source[match.end(0)...].to_s
      !suffix.match?(/\A(?:点|限(?:目)?)(?:\z|[ \t、。,;；・･]|に|の|で|を|は|が|から|まで)/)
    end

    def valid_clock_time?(hour, minute)
      hour.to_i.between?(0, 23) && minute.to_i.between?(0, 59)
    end

    def invalid_explicit_time_range_match(text)
      clock_scan = explicit_clock_scan(text)
      ranges = explicit_time_range_matches(clock_scan[:source], scan: clock_scan)
      invalid_range = ranges.find do |range|
        range[:start_minute] && range[:end_minute] && range[:end_minute] <= range[:start_minute]
      end
      return invalid_range if invalid_range

      shared_date = first_local_date_from_text(clock_scan[:source])
      dates_by_clause = {}
      ranges.each do |range|
        clause_key = [range[:clause_start_index], range[:clause_end_index]]
        range_date = dates_by_clause.fetch(clause_key) do
          clause_source = if clause_key.all?
                            clock_scan[:source][clause_key.first...clause_key.last].to_s
                          end
          dates_by_clause[clause_key] = first_local_date_from_text(clause_source) || shared_date
        end
        next unless range_date

        start_at = local_time_at_minute(range_date, range[:start_minute])
        end_at = local_time_at_minute(range_date, range[:end_minute])
        next if start_at && end_at && end_at > start_at

        return range.merge(invalid_local_clock: true)
      end

      ranges.each do |range|
        cue_match = unbound_range_start_overnight_cue_match(clock_scan[:source], range)
        next unless cue_match

        return range.merge(
          raw: clock_scan[:source][cue_match.begin(0)...range[:end_index]],
          unbound_overnight_cue: true
        )
      end

      nil
    end

    def explicit_time_range_matches(text, scan: nil)
      clock_scan = scan || explicit_clock_scan(text)
      normalized = clock_scan[:source]
      ranges = []

      clock_scan[:tokens].each_cons(2) do |start_token, end_token|
        next unless start_token[:valid] && end_token[:valid]

        connector = normalized[start_token[:end_index]...end_token[:start_index]].to_s
        connector_details = explicit_time_range_connector_details(connector, end_token)
        next unless connector_details

        start_minute = start_token[:hour] * 60 + start_token[:minute]
        clock_end_minute = end_token[:hour] * 60 + end_token[:minute]
        end_hour = end_token[:hour]
        if connector_details[:overnight_cue].blank? && end_token[:period].blank? && start_token[:period].present?
          raw_end_minute = end_token[:unadjusted_hour] * 60 + end_token[:minute]
          inherited_hour = adjust_hour_for_period(end_token[:unadjusted_hour], start_token[:period])
          inherited_end_minute = inherited_hour * 60 + end_token[:minute]
          end_hour = inherited_hour if raw_end_minute <= start_minute && inherited_end_minute > start_minute
        end
        next unless valid_clock_time?(end_hour, end_token[:minute])

        end_index = end_token[:end_index]
        if (suffix = normalized[end_index...].to_s.match(/\A[ \t]*まで/))
          end_index += suffix.end(0)
        end

        resolved_end_minute = end_hour * 60 + end_token[:minute]
        day_offset_minutes = connector_details[:overnight_cue].present? ? 24 * 60 : 0

        ranges << {
          raw: normalized[start_token[:start_index]...end_index],
          start_minute: start_minute,
          clock_end_minute: clock_end_minute,
          day_offset_minutes: day_offset_minutes,
          end_minute: (day_offset_minutes.positive? ? clock_end_minute : resolved_end_minute) + day_offset_minutes,
          overnight_cue: connector_details[:overnight_cue],
          overnight_cue_bound: connector_details[:overnight_cue].present?,
          cue_spans: [],
          start_index: start_token[:start_index],
          end_index: end_index,
          start_token: start_token,
          end_token: end_token
        }
      end

      bind_day_crossing_annotations(
        normalized,
        ranges,
        clause_spans: time_range_clause_spans(normalized)
      )
    end

    def explicit_time_range_connector_details(connector, end_token)
      normalized = connector.to_s.strip
      if (match = normalized.match(/\A(?:から|〜|~|-)\s*(翌日|翌朝)\z/))
        cue = match[1] == '翌朝' ? :next_morning : :next_day
        return { overnight_cue: cue }
      end
      if normalized.match?(/\A(?:から|〜|~|-)\s*翌\z/) && normalize_japanese(end_token[:period]) == '朝'
        return { overnight_cue: :next_morning }
      end
      return { overnight_cue: nil } if normalized.match?(/\A(?:から|〜|~|-)\z/)

      nil
    end

    def bind_day_crossing_annotations(source, ranges, clause_spans:)
      bound_ranges = ranges.map(&:dup)
      ranges_by_clause = Hash.new { |hash, key| hash[key] = [] }
      clause_index = 0

      bound_ranges.each do |range|
        clause_index += 1 while clause_index < clause_spans.length && range[:start_index] >= clause_spans[clause_index].end
        clause_span = clause_spans[clause_index]
        next unless clause_span && range[:start_index] >= clause_span.begin && range[:end_index] <= clause_span.end

        range[:clause_start_index] = clause_span.begin
        range[:clause_end_index] = clause_span.end
        ranges_by_clause[clause_index] << range
      end

      clause_spans.each_index do |index|
        clause_ranges = ranges_by_clause[index]
        next unless clause_ranges.one?

        range = clause_ranges.sole
        clause_span = clause_spans[index]
        tail = source[range[:end_index]...clause_span.end].to_s
        annotation = tail.match(/\([ \t]*日またぎ[ \t]*\)[ \t]*\z/)
        next unless annotation
        next unless day_crossing_annotation_title_tail?(tail[0...annotation.begin(0)])

        annotation_span = (range[:end_index] + annotation.begin(0))...(range[:end_index] + annotation.end(0))
        range[:cue_spans] = Array(range[:cue_spans]) + [annotation_span]
        next if range[:overnight_cue_bound]

        range[:day_offset_minutes] = 24 * 60
        range[:end_minute] = range[:clock_end_minute] + range[:day_offset_minutes]
        range[:overnight_cue] = :day_crossing_annotation
        range[:overnight_cue_bound] = true
      end

      bound_ranges
    end

    def time_range_clause_spans(source)
      spans = []
      clause_start = 0
      delimiter_ranges = []
      source.to_enum(:scan, /(?:\r?\n|[。,;；])/).each do
        delimiter = Regexp.last_match
        delimiter_ranges << (delimiter.begin(0)...delimiter.end(0))
      end
      safe_period_event_boundary_indexes(source).each do |index|
        delimiter_ranges << (index...(index + 1))
      end

      delimiter_ranges.sort_by(&:begin).each do |delimiter_range|
        spans << (clause_start...delimiter_range.begin)
        clause_start = delimiter_range.end
      end
      spans << (clause_start...source.length)
      spans
    end

    def day_crossing_annotation_title_tail?(tail)
      return true unless tail.include?('、')

      fragments = tail.split(/(、)/, -1)
      current = fragments.shift.to_s
      fragments.each_slice(2) do |_delimiter, right|
        right = right.to_s
        numeric_continuation = current.rstrip.match?(/\d\z/) && right.lstrip.match?(/\A\d/)
        latin_continuation = current.rstrip.match?(/[\p{Latin}][\p{Latin}\d+.#&_-]*\z/) &&
                             right.lstrip.match?(/\A[\p{Latin}][\p{Latin}\d+.#&_-]*(?=[\p{Han}\p{Hiragana}\p{Katakana}])/)
        return false unless numeric_continuation || latin_continuation

        current = "#{current}、#{right}"
      end

      true
    end

    def unbound_range_start_overnight_cue_match(source, range)
      clause_start_index = range[:clause_start_index]
      clause_end_index = range[:clause_end_index]
      return nil unless clause_start_index && clause_end_index

      prefix = source[clause_start_index...range[:start_token][:start_index]].to_s
      prefix.match(/(?:翌日|翌朝)(?:[ \t]*の)?[ \t]*\z/) ||
        (normalize_japanese(range[:start_token][:period]) == '朝' && prefix.match(/翌(?:[ \t]*の)?[ \t]*\z/))
    end

    def parse_local_time_and_duration(text, default_duration:)
      timing = parse_local_schedule_timing(text, default_duration: default_duration)
      [timing[:start_minute], timing[:duration_minutes]]
    end

    def parse_local_schedule_timing(text, default_duration:)
      clock_scan = explicit_clock_scan(text)
      normalized = clock_scan[:source]
      clock_matches = explicit_time_matches(normalized, scan: clock_scan)
      explicit_range = explicit_time_range_matches(normalized, scan: clock_scan).first
      explicit_duration = explicit_duration_minutes(
        text_outside_clock_matches(normalized, clock_matches)
      )
      start_clock_match = explicit_range ? explicit_range[:start_token] : clock_matches.first
      end_clock_match = explicit_range&.fetch(:end_token, nil)
      range_duration = explicit_range && explicit_range[:end_minute] - explicit_range[:start_minute]
      range_duration = nil unless range_duration&.positive?

      {
        start_minute: explicit_range ? explicit_range[:start_minute] : explicit_start_minute_from_text(normalized, scan: clock_scan),
        start_time_match_range: match_range(start_clock_match),
        end_minute: explicit_range&.fetch(:end_minute, nil),
        end_time_match_range: match_range(end_clock_match),
        explicit_duration_minutes: explicit_duration,
        duration_minutes: explicit_range ? range_duration : explicit_duration.presence || default_duration,
        duration_explicit: explicit_duration.present?,
        end_time_explicit: explicit_range.present?
      }
    end

    def explicit_duration_minutes(text)
      normalized = normalize_japanese(text)
      return -1 if negative_duration_expression_match(normalized)

      if (match = normalized.match(/(?<hours>\d+(?:\.\d+)?)\s*時間\s*半/))
        return (match[:hours].to_f * 60).to_i + 30
      end

      if (match = normalized.match(/(?<hours>\d+(?:\.\d+)?)\s*時間\s*(?<minutes>\d+)\s*分/))
        return (match[:hours].to_f * 60).to_i + match[:minutes].to_i
      end

      if (match = normalized.match(/(?<hours>\d+(?:\.\d+)?)\s*時間/))
        return (match[:hours].to_f * 60).to_i
      end

      if (match = normalized.match(/(?<minutes>\d+)\s*分/))
        return match[:minutes].to_i
      end

      nil
    end

    def negative_duration_expression_match(text)
      normalize_japanese(text).match(NEGATIVE_DURATION_EXPRESSION_PATTERN)
    end

    def text_outside_clock_matches(text, matches)
      characters = text.each_char.to_a
      matches.each do |match|
        (match[:start_index]...match[:end_index]).each { |index| characters[index] = ' ' }
      end
      characters.join
    end

    def match_range(match)
      return nil unless match

      match[:start_index]...match[:end_index]
    end

    def explicit_start_minute_from_text(text, scan: nil)
      clock_scan = scan || explicit_clock_scan(text)
      token = explicit_time_matches(clock_scan[:source], scan: clock_scan).first
      return token[:hour] * 60 + token[:minute] if token
      return 12 * 60 if clock_scan[:source].match?(/正午/)

      nil
    end

    def adjust_hour_for_period(hour, period)
      normalized_period = normalize_japanese(period)

      case normalized_period
      when 'pm', '午後', '夕方', '放課後', '夜', 'よる', '今夜', '今晩'
        hour += 12 if hour.between?(1, 11)
      when 'am', '午前', '朝', '午前中', '深夜', '未明'
        hour = 0 if hour == 12
      when '昼', 'お昼'
        hour += 12 if hour.between?(1, 5)
      end

      hour
    end

    def normalize_period_words(text)
      normalize_japanese(text)
        .gsub(/(午前|朝)\s*12時(?!間)/, '0時')
        .gsub(/(深夜|未明)\s*(\d{1,2})([:：]\d{2})/) { "#{deep_night_hour(Regexp.last_match[2].to_i)}#{Regexp.last_match[3]}" }
        .gsub(/(深夜|未明)\s*(\d{1,2})時(?!間)/) { "#{deep_night_hour(Regexp.last_match[2].to_i)}時" }
        .gsub(/(午後|夕方|放課後|夜|今夜|今晩)\s*(\d{1,2})([:：]\d{2})/) { "#{period_hour(Regexp.last_match[2].to_i)}#{Regexp.last_match[3]}" }
        .gsub(/(午後|夕方|放課後|夜|今夜|今晩)\s*(\d{1,2})時(?!間)/) { "#{period_hour(Regexp.last_match[2].to_i)}時" }
        .gsub(/(午前|朝)\s*(\d{1,2})時(?!間)/) { "#{Regexp.last_match[2].to_i}時" }
    end

    def preferred_minute_window(text)
      normalized = normalize_period_words(normalize_japanese(text))
      return [13 * 60, 18 * 60] if normalized.include?('午後')
      return [12 * 60, 14 * 60] if normalized.match?(/昼|正午/)
      return [9 * 60, 12 * 60] if normalized.match?(/午前|朝/)
      return [17 * 60, 20 * 60] if normalized.match?(/夕方|放課後/)
      return [1 * 60, 4 * 60] if normalized.match?(/深夜|未明/)
      return [18 * 60, 22 * 60] if normalized.match?(/夜|今夜|今晩/)
      [9 * 60, 18 * 60]
    end

    def free_for_all?(start_at, end_at, participant_names:, buffer_minutes: 0)
      check_start = start_at - buffer_minutes.to_i.minutes
      check_end = end_at + buffer_minutes.to_i.minutes
      return false if conflicts_with_events?(context_value(:personal_events), check_start, check_end)
      return false if conflicts_with_events?(matching_peer_events(participant_names), check_start, check_end)
      return false unless fits_contact_profiles?(participant_names, start_at, end_at)
      true
    end

    def conflicts_with_events?(events, start_at, end_at)
      Array(events).any? do |event|
        next false unless event.respond_to?(:to_h)
        attrs = event.to_h
        s = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
        e = app_time_zone.parse((attrs[:end_at] || attrs['end_at']).to_s) rescue nil
        s && e && e > start_at && s < end_at
      end
    end

    def matching_peer_events(names)
      normalized_names = Array(names).map { |name| normalize_japanese(name) }.reject(&:blank?)
      Array(context_value(:peer_events)).select do |event|
        peer_name = normalize_japanese(event[:peer_name] || event['peer_name'])
        normalized_names.any? { |name| peer_name.include?(name) || name.include?(peer_name) }
      end
    end

    def fits_contact_profiles?(names, start_at, end_at)
      contacts = Array(context_value(:contacts)).select do |contact|
        name = normalize_japanese(contact[:display_name] || contact['display_name'])
        Array(names).any? { |n| name.include?(normalize_japanese(n)) || normalize_japanese(n).include?(name) }
      end
      return true if contacts.empty?
      contacts.all? do |contact|
        profiles = Array(contact[:availability_profiles] || contact['availability_profiles'])
        next true if profiles.empty?
        profiles.any? do |profile|
          attrs = profile.to_h
          weekday = attrs[:weekday] || attrs['weekday']
          start_minute = attrs[:start_minute] || attrs['start_minute']
          end_minute = attrs[:end_minute] || attrs['end_minute']
          weekday.to_i == start_at.wday && start_minute.to_i <= start_at.hour * 60 + start_at.min && end_minute.to_i >= end_at.hour * 60 + end_at.min
        end
      end
    end

    def participant_name_tokens_from_text(text)
      source = normalize_japanese_preserve_case(remove_date_time_phrases(text))
      source
        .scan(/([一-龥ぁ-んァ-ヶA-Za-z0-9_\-]+?)(?:さん|くん|君|ちゃん)?(?:と|との)(?=会議|定例|打ち合わせ|打合せ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|チャット|会う|遊ぶ|相談|予定)/)
        .flatten
        .map { |name| clean_activity_title(name) }
        .reject(&:blank?)
    end

    def matched_existing_events(text)
      date = first_local_date_from_text(text)
      title = local_title_from_text(text)
      descriptor = local_event_descriptor(text)
      names = (Array(descriptor[:participant_names]) + participant_name_tokens_from_text(text))
              .map { |name| normalize_japanese(name) }
              .reject(&:blank?)
              .uniq
      normalized_title = normalize_japanese(title)
      normalized_request = normalize_japanese(text)
      normalized_query_title = existing_event_title_query_from_text(text)

      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)

        attrs = event.to_h
        event_title = attrs[:title] || attrs['title']
        normalized_event_title = normalize_japanese(event_title)
        start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])

        title_match =
          if normalized_query_title.present?
            normalized_event_title.include?(normalized_query_title) ||
              normalized_query_title.include?(normalized_event_title)
          else
            activity_match = existing_event_activity_match?(normalized_event_title, normalized_request)
            normalized_title.blank? || normalized_event_title.include?(normalized_title) || activity_match
          end

        name_match = names.empty? || names.any? { |name| normalized_event_title.include?(name) }
        date_match = date.blank? || (start_at && start_at.to_date == date)

        title_match && name_match && date_match
      end
    end

    def existing_event_activity_match?(event_title, request_text)
      request_tokens = existing_event_activity_tokens(request_text)
      event_tokens = existing_event_activity_tokens(event_title)
      (request_tokens & event_tokens).any?
    end

    def existing_event_activity_tokens(text)
      normalized = normalize_japanese(text)
      tokens = []
      tokens << 'meeting' if normalized.match?(/会議|ミーティング/)
      tokens << 'discussion' if normalized.match?(/打ち合わせ|打合せ/)
      tokens << 'regular_meeting' if normalized.match?(/定例/)
      tokens << 'consultation' if normalized.match?(/相談/)
      tokens << 'phone' if normalized.match?(/電話|tel|コール|call/)
      tokens << 'meal' if normalized.match?(/飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー/)
      tokens << 'trip' if normalized.match?(/旅行/)
      tokens << 'review' if normalized.match?(/レビュー/)
      tokens << 'hospital' if normalized.match?(/通院|病院/)
      tokens << 'chat' if normalized.match?(/チャット/)
      tokens << 'meetup' if normalized.match?(/会う|遊ぶ/)
      tokens
    end

    def format_event_for_message(event)
      attrs = event.to_h
      start_at = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
      title = attrs[:title] || attrs['title']
      start_at ? "#{start_at.strftime('%-m/%-d %H:%M')} #{title}" : title.to_s
    end


    def travel_time_assist_request?(text)
      normalized = normalize_japanese(text)
      return false if existing_event_delete_request?(normalized) || reminder_request?(normalized)
      return false if normalized.match?(/変更|ずらして|リスケ|延期|前倒し|削除|消して|消す|消したい|キャンセル|取り消し|通知|リマインダー/)
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return false if explicit_all_day_request?(normalized)

      date = first_local_date_from_text(normalized)
      start_minute, = parse_local_time_and_duration(normalized, default_duration: 60)
      return false unless date && start_minute

      route = extract_travel_route(normalized)
      has_travel_details = route[:travel_minutes].to_i.positive? || normalized.match?(/移動時間|移動に|移動も|到着|着きたい|出発/)

      has_travel_details
    end

    def extract_travel_route(text)
      normalized = normalize_japanese_preserve_case(text)
      compact = normalized.gsub(/[、。]/, ' ')
      result = { origin: nil, destination: nil, travel_minutes: nil }

      if (match = compact.match(/(?<origin>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})から(?<destination>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})まで(?:の)?(?:移動(?:時間)?は?|所要時間は?)?\s*(?<minutes>\d{1,3})\s*分/)) &&
         !travel_route_match_overlaps_clock?(compact, match)
        result[:origin] = clean_travel_place(match[:origin])
        result[:destination] = clean_travel_place(match[:destination])
        result[:travel_minutes] = bounded_minutes(match[:minutes], min: 5, max: 240)
        return result
      end

      if (match = compact.match(/(?<origin>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})から(?<destination>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})(?:へ|に|まで)/)) &&
         !travel_route_match_overlaps_clock?(compact, match)
        result[:origin] = clean_travel_place(match[:origin])
        result[:destination] = clean_travel_place(match[:destination])
      end

      result[:travel_minutes] ||= extract_travel_minutes(compact)
      result
    end

    def travel_route_match_overlaps_clock?(text, route_match)
      explicit_time_matches(text).any? do |clock|
        route_match.begin(0) < clock[:end_index] && route_match.end(0) > clock[:start_index]
      end
    end

    def extract_travel_minutes(text)
      normalized = normalize_japanese(text)
      if (match = normalized.match(/移動(?:時間)?(?:は|に|で)?\s*(?<minutes>\d{1,3})\s*分/))
        return bounded_minutes(match[:minutes], min: 5, max: 240)
      end
      if (match = normalized.match(/(?<minutes>\d{1,3})\s*分\s*(?:移動|かかる|見て|みて)/))
        return bounded_minutes(match[:minutes], min: 5, max: 240)
      end
      nil
    end

    def extract_arrival_buffer_minutes(text)
      normalized = normalize_japanese(text)
      if (match = normalized.match(/(?<minutes>\d{1,3})\s*分前(?:に)?(?:到着|着きたい|着く)/))
        return bounded_minutes(match[:minutes], min: 0, max: 180)
      end
      if (match = normalized.match(/到着(?:バッファ|余裕)?\s*(?<minutes>\d{1,3})\s*分/))
        return bounded_minutes(match[:minutes], min: 0, max: 180)
      end
      0
    end

    def bounded_minutes(value, min:, max:)
      minutes = value.to_i
      return nil if minutes < min || minutes > max
      minutes
    end

    def clean_travel_place(value)
      raw = normalize_japanese_preserve_case(value)
      cleaned = remove_date_time_phrases(raw)
        .gsub(/\A(?:明日|あした|今日|きょう|来週|今週|再来週|に|で|を|と|の|から|まで|へ)+/, '')
        .gsub(/(?:に|で|を|と|の|から|まで|へ)\z/, '')
        .strip
      cleaned.presence
    end

    def remove_travel_assist_phrases(text, destination:, origin: nil)
      value = normalize_japanese_preserve_case(text)

      # Phase 5-A: route travel duration must not become the main event duration.
      # Example:
      #   自宅から大阪駅まで45分、明日10時に会議、15分前に到着
      # should mean travel=45min and meeting=default 60min, not meeting=45min.
      if origin.present? && destination.present?
        origin_pattern = Regexp.escape(origin.to_s)
        destination_pattern = Regexp.escape(destination.to_s)
        value = value.gsub(/#{origin_pattern}\s*から\s*#{destination_pattern}\s*まで(?:の)?(?:移動(?:時間)?は?|所要時間は?)?\s*\d{1,3}\s*分/, '')
        value = value.gsub(/#{origin_pattern}\s*から\s*#{destination_pattern}(?:へ|に|まで)/, '')
      elsif destination.present?
        destination_pattern = Regexp.escape(destination.to_s)
        value = value.gsub(/#{destination_pattern}\s*まで(?:の)?(?:移動(?:時間)?は?|所要時間は?)?\s*\d{1,3}\s*分/, '')
      end

      [origin, destination].compact.each do |place|
        escaped = Regexp.escape(place.to_s)
        value = value.gsub(/#{escaped}(?:で|に|へ|まで|から)?/, '')
      end
      value
        .gsub(/移動(?:時間)?(?:は|に|で)?\s*\d{1,3}\s*分/, '')
        .gsub(/\d{1,3}\s*分\s*(?:移動|かかる|見て|みて)/, '')
        .gsub(/\d{1,3}\s*分前(?:に)?(?:到着|着きたい|着く)/, '')
        .gsub(/到着(?:バッファ|余裕)?\s*\d{1,3}\s*分/, '')
        .gsub(/(?:から|まで|へ|に)\s*/, ' ')
        .strip
    end

    def travel_assist_main_title(title_source, descriptor)
      source = remove_date_time_phrases(title_source)
        .sub(/(?:、|,)?[ \t]*移動(?:時間)?[ \t]*\z/, '')
        .sub(/(?:、|,)?[ \t]*前[ \t]*(?:に[ \t]*)?(?:到着|着きたい|着く)[ \t]*\z/, '')
      title = clean_activity_title(source)
      title = descriptor[:activity_title].presence || descriptor[:title] if insufficient_activity_title?(title) || title == '予定'
      clean_activity_title(title)
    end

    def travel_assist_main_description(destination:, arrival_buffer_minutes:)
      parts = ['AI秘書提案の予定候補']
      parts << "目的地: #{destination}" if destination.present?
      parts << "到着バッファ: #{arrival_buffer_minutes}分" if arrival_buffer_minutes.to_i.positive?
      parts.join(' / ')
    end

    def travel_event_hash(origin:, destination:, start_at:, end_at:, travel_minutes:, arrival_buffer_minutes:)
      title = origin.present? ? "移動: #{origin} → #{destination}" : "移動: #{destination}へ"
      payload = local_event_hash(
        title: title,
        start_at: start_at,
        end_at: end_at,
        all_day: false,
        color: '#06b6d4',
        category: 'personal',
        intent: 'travel',
        schedule_profile: 'travel',
        reason: '本予定に間に合うよう、明示された移動時間から逆算しました。',
        location: destination,
        buffer_minutes: arrival_buffer_minutes
      )
      payload['description'] = travel_label(origin: origin, destination: destination)
      payload['travel_assist'] = {
        'origin' => origin,
        'destination' => destination,
        'travel_minutes' => travel_minutes,
        'arrival_buffer_minutes' => arrival_buffer_minutes,
        'phase' => '5a'
      }.compact
      payload
    end

    def travel_label(origin:, destination:)
      origin.present? ? "#{origin}から#{destination}へ移動" : "#{destination}へ移動"
    end

    def extract_local_location(text)
      source = remove_date_time_phrases(text)
      activity = local_location_activity_pattern
      patterns = [
        /(?<location>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{2,30})で(?=#{activity})/,
        /(?<location>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{2,30})(?:に|へ)(?=#{activity})/
      ]

      patterns.each do |pattern|
        match = source.match(pattern)
        next unless match

        location = clean_travel_place(match[:location])
        return location if valid_local_location?(location)
      end

      nil
    end

    def local_location_activity_pattern
      /会議|定例|打ち合わせ|打合せ|ミーティング|飲み会|食事|旅行|通院|レビュー|予定|面談|商談|挨拶|掃除|買い物/
    end

    def valid_local_location?(location)
      normalized = normalize_japanese(location)
      return false if normalized.blank? || normalized.length < 2
      return false if normalized.match?(/\A(?:ま|で|に|へ|の|を|と|から|まで)+\z/)
      return false if normalized.match?(/(?:さん|くん|君|ちゃん)\z/)

      true
    end

    def extract_local_buffer_minutes(text)
      normalized = normalize_japanese(text)
      return Regexp.last_match[:minutes].to_i if normalized.match(/前後\s*(?<minutes>\d{1,3})\s*分/)
      return Regexp.last_match[:minutes].to_i if normalized.match(/(?<minutes>\d{1,3})\s*分\s*(?:空けて|あけて|バッファ)/)
      nil
    end

    def local_reason_for_participants(names)
      names = Array(names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      names.empty? ? '指定内容に合わせて予定候補を作成しました。' : "#{names.join('・')}との予定として候補を作成しました。"
    end

    def period_hour(hour)
      (1..11).include?(hour) ? hour + 12 : hour
    end

    def deep_night_hour(hour)
      hour == 12 ? 0 : hour
    end

    def duration_value_to_minutes(value, unit)
      number = value.to_f
      minutes = if unit.to_s.include?('分')
                  number.round
                elsif unit.to_s.include?('時間')
                  (number * 60).round
                elsif number <= 12
                  (number * 60).round
                else
                  number.round
                end
      return nil if minutes <= 0

      [[minutes, 5].max, 480].min
    end

    def next_weekday_on_or_after(date, weekday)
      date + ((weekday - date.wday) % 7)
    end

    def beginning_of_week(date)
      date - ((date.wday + 6) % 7)
    end

    def relative_day_count_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<count>\d+|一|二|三|四|五|六|七|八|九|十|十一|十二|十三|十四|十五|十六|十七|十八|十九|二十)(?:日|にち)後/)
      return nil unless match

      count = japanese_integer(match[:count])
      return nil unless count&.positive?

      now.to_date + count
    end

    def relative_final_weekday_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<rel>再来月|来月|今月)の?最終(?<weekday>[月火水木金土日])(?:曜日|曜)?/)
      return nil unless match

      month_offset = case match[:rel]
                     when '再来月' then 2
                     when '来月' then 1
                     else 0
                     end
      target_month = now.to_date >> month_offset
      last_day = target_month.end_of_month
      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless weekday

      last_day - ((last_day.wday - weekday) % 7)
    end

    def japanese_integer(value)
      raw = value.to_s
      return raw.to_i if raw.match?(/\A\d+\z/)

      digits = {
        '〇' => 0, '零' => 0,
        '一' => 1, '二' => 2, '三' => 3, '四' => 4, '五' => 5,
        '六' => 6, '七' => 7, '八' => 8, '九' => 9
      }
      return digits[raw] if digits.key?(raw)
      return 10 if raw == '十'

      if raw.include?('十')
        head, tail = raw.split('十', 2)
        tens = head.blank? ? 1 : digits[head]
        ones = tail.blank? ? 0 : digits[tail]
        return nil if tens.nil? || ones.nil?

        tens * 10 + ones
      end
    end

    def relative_weekday_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<rel>再来週|来週|翌週|今週)?(?:の)?\s*(?<weekday>[月火水木金土日])(?:曜日|曜)/)
      return nil unless match

      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless weekday

      date = case match[:rel].to_s
             when '再来週'
               week_start = beginning_of_week(now.to_date) + 14
               week_start + ((weekday - week_start.wday) % 7)
             when '来週', '翌週'
               week_start = beginning_of_week(now.to_date) + 7
               week_start + ((weekday - week_start.wday) % 7)
             when '今週'
               week_start = beginning_of_week(now.to_date)
               week_start + ((weekday - week_start.wday) % 7)
             else
               next_weekday_on_or_after(now.to_date, weekday)
             end

      match[:rel].to_s == '今週' && date < now.to_date ? date + 7 : date
    end

    def relative_nth_weekday_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?:(?<rel>来月|翌月|今月)の?)?第(?<ordinal>[1-5一二三四五])(?<weekday>[月火水木金土日])(?:曜日|曜)?/)
      return nil unless match

      ordinal = japanese_ordinal_to_i(match[:ordinal])
      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless ordinal && weekday

      year = now.year
      month = now.month
      if match[:rel].to_s.match?(/来月|翌月/)
        year, month = add_months(year, month, 1)
      end

      date = nth_weekday_date(year, month, weekday, ordinal)
      if date && match[:rel].blank? && date < now.to_date
        year, month = add_months(year, month, 1)
        date = nth_weekday_date(year, month, weekday, ordinal)
      end
      date
    end

    def add_months(year, month, count)
      index = year * 12 + (month - 1) + count
      [index / 12, index % 12 + 1]
    end

    def nth_weekday_date(year, month, weekday, ordinal)
      first = Date.new(year, month, 1)
      date = first + ((weekday - first.wday) % 7) + ((ordinal - 1) * 7)
      date.month == month ? date : nil
    rescue StandardError
      nil
    end

    def japanese_ordinal_to_i(value)
      { '一' => 1, '二' => 2, '三' => 3, '四' => 4, '五' => 5 }.fetch(value.to_s, value.to_i)
    end

    def minute_label(minute)
      "#{minute / 60}:#{(minute % 60).to_s.rjust(2, '0')}"
    end

    def local_duration_label(duration)
      minutes = duration.to_i
      return "#{minutes / 60}時間" if (minutes % 60).zero?
      return "#{minutes / 60}時間#{minutes % 60}分" if minutes > 60

      "#{minutes}分"
    end

    def explicit_all_day_request?(text)
      normalize_japanese(text).match?(/終日|一日中|1日中|丸一日|まる一日|全日|all\s*day/i)
    end

    def default_start_minute_for_text(text, title)
      return preferred_minute_window(text).first if period_window_hint?(text)

      default_start_minute_for_title(title)
    end

    def period_window_hint?(text)
      normalize_japanese(text).match?(/午後|午前|朝イチ|朝一|朝|昼|正午|夕方|放課後|深夜|未明|夜|今夜|今晩/)
    end

    def default_start_minute_for_title(title)
      return 10 * 60 if title.to_s.match?(/集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間|課題時間|課題|宿題|復習|勉強|学習/)
      return 7 * 60 if title.to_s.match?(/ストレッチ|体操/)

      title.to_s.match?(/飲み|食事|ランチ|ディナー/) ? 18 * 60 : 9 * 60
    end

    def default_duration_minutes_for_title(title)
      case title
      when /飲み|食事/ then 120
      when /旅行|出張|滞在|観光|宿泊|帰省/ then 240
      when /ストレッチ|体操|休憩/ then 10
      when /電話|チャット/ then 30
      when /集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間|課題時間|課題|宿題|復習|勉強|学習/ then 90
      when /定例|会議|調整|レビュー/ then 60
      else 60
      end
    end

    def color_for_local_title(title)
      title.to_s.match?(/飲み|食事|旅行|出張|滞在|観光|宿泊|帰省|会う|チャット|休憩|ストレッチ/) ? '#f97316' : '#3b82f6'
    end

    def category_for_local_title(title)
      return 'travel' if title.to_s.match?(/旅行|出張|滞在|観光|宿泊|帰省/)
      return 'leisure' if title.to_s.match?(/飲み|食事|会う|チャット|休憩|ストレッチ/)
      return 'study' if title.to_s.match?(/学校|課題|宿題|復習|勉強|学習/)

      'work'
    end

    def intent_for_local_title(title)
      case title
      when /飲み|食事/ then 'meal'
      when /旅行|出張|滞在|観光|宿泊|帰省/ then 'travel'
      when /会う|チャット/ then 'social'
      when /休憩/ then 'break'
      when /ストレッチ|体操/ then 'routine'
      when /学校|課題|宿題|復習|勉強|学習/ then 'study'
      when /集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間/ then 'focus_work'
      when /定例|会議/ then 'meeting'
      else 'general'
      end
    end

    def profile_for_local_title(title)
      return 'social' if title.to_s.match?(/飲み|食事|会う|チャット/)
      return 'travel' if title.to_s.match?(/旅行|出張|滞在|観光|宿泊|帰省/)
      return 'routine' if title.to_s.match?(/ストレッチ|体操/)
      return 'study' if title.to_s.match?(/学校|課題|宿題|復習|勉強|学習/)
      return 'focus_work' if title.to_s.match?(/集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間/)

      'work'
    end

    # === END CF_LOCAL_STRUCTURED_AI_V5 ===




    def request_remote
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      uri = URI.parse("#{service_url}/chat/respond")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 3
      http.read_timeout = DEFAULT_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(
        {
          scope: context_value(:scope),
          user_message: @user_message,
          refresh_only: @refresh_only,
          context: @context
        }
      )

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "AI service error: HTTP #{response.code}"
      end

      parsed = JSON.parse(response.body)
      duration_ms = elapsed_ms(started_at)
      provider = parsed['provider'].presence || 'rules-v4-work-intent'

      {
        assistant_message: parsed['assistant_message'].to_s,
        recommendations: Array(parsed['recommendations']),
        provider: provider,
        policy_run: normalize_policy_run(parsed['policy_run'], provider: provider, duration_ms: duration_ms),
        tool_invocations: normalize_tool_invocations(parsed['tool_invocations'])
      }
    end

    def service_url
      explicit_url = ENV['AI_SERVICE_URL'].to_s.strip
      return explicit_url if explicit_url.present?

      internal_hostport = ENV['AI_SERVICE_HOSTPORT'].to_s.strip
      return "http://#{internal_hostport}" if internal_hostport.present?

      'http://127.0.0.1:8001'
    end

    def fallback_response(error)
      candidate_events = Array(context_value(:candidate_group_events)).first(3)
      recommendations = candidate_events.map do |event|
        {
          'kind' => 'group_event_copy',
          'title' => event[:title] || event['title'],
          'description' => event[:description] || event['description'],
          'reason' => 'AIサービスに接続できなかったため、所属グループの近日イベントを候補表示しています。',
          'start_at' => event[:start_at] || event['start_at'],
          'end_at' => event[:end_at] || event['end_at'],
          'all_day' => event[:all_day] || event['all_day'],
          'source_event_id' => event[:id] || event['id'],
          'payload' => {
            source_event_id: event[:id] || event['id'],
            title: event[:title] || event['title'],
            description: event[:description] || event['description'],
            start_at: event[:start_at] || event['start_at'],
            end_at: event[:end_at] || event['end_at'],
            all_day: event[:all_day] || event['all_day'],
            location: event[:location] || event['location'],
            color: event[:color] || event['color']
          }
        }
      end

      message = if recommendations.any?
                  'AIサービスに接続できませんでした。代わりに、近日のグループイベント候補を表示します。'
                else
                  'AIサービスに接続できませんでした。少し時間をおいて再試行してください。'
                end

      {
        assistant_message: message,
        recommendations: recommendations,
        provider: 'rails-fallback',
        policy_run: {
          provider: 'rails-fallback',
          policy_version: 'rails-fallback',
          route: 'fallback',
          request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
          prompt_snapshot: {
            user_message: @user_message,
            refresh_only: @refresh_only,
            scope: context_value(:scope)
          },
          context_snapshot: {
            scope: context_value(:scope),
            candidate_group_event_count: Array(context_value(:candidate_group_events)).size,
            contact_count: Array(context_value(:contacts)).size,
            friend_count: Array(context_value(:friends)).size
          },
          result_metadata: {
            error_class: error.class.name,
            error_message: error.message,
            recommendation_count: recommendations.length,
            fallback: true
          }
        },
        tool_invocations: [
          {
            tool_name: 'rails_fallback_candidate_events',
            status: 'fallback',
            position: 1,
            input_payload: {
              candidate_group_event_count: Array(context_value(:candidate_group_events)).size
            },
            output_payload: {
              recommendation_count: recommendations.length
            },
            metadata: {
              error_class: error.class.name,
              error_message: error.message
            }
          }
        ]
      }
    end

    def normalize_policy_run(raw_policy_run, provider:, duration_ms:)
      raw = raw_policy_run.to_h.stringify_keys
      {
        provider: raw['provider'].presence || provider,
        policy_version: raw['policy_version'].presence || provider,
        route: raw['route'].presence || 'rules_engine',
        request_kind: raw['request_kind'].presence || (@refresh_only ? 'refresh_only' : 'chat_message'),
        duration_ms: integer_or_nil(raw['duration_ms']) || duration_ms,
        prompt_snapshot: normalize_hash(raw['prompt_snapshot']),
        context_snapshot: normalize_hash(raw['context_snapshot']),
        result_metadata: normalize_hash(raw['result_metadata'])
      }
    rescue StandardError
      {
        provider: provider,
        policy_version: provider,
        route: 'rules_engine',
        request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
        duration_ms: duration_ms,
        prompt_snapshot: {},
        context_snapshot: {},
        result_metadata: {}
      }
    end

    def normalize_tool_invocations(raw_tool_invocations)
      Array(raw_tool_invocations).each_with_index.map do |raw, index|
        attrs = raw.to_h.stringify_keys
        {
          tool_name: attrs['tool_name'].presence || attrs['name'].presence || "tool_#{index + 1}",
          status: attrs['status'].presence || 'success',
          position: integer_or_nil(attrs['position']) || index + 1,
          duration_ms: integer_or_nil(attrs['duration_ms']),
          input_payload: normalize_hash(attrs['input_payload'] || attrs['input']),
          output_payload: normalize_hash(attrs['output_payload'] || attrs['output']),
          metadata: normalize_hash(attrs['metadata'])
        }
      end
    rescue StandardError
      []
    end

    def normalize_japanese(value)
      value.to_s.unicode_normalize(:nfkc).downcase.strip
    rescue StandardError
      value.to_s.downcase.strip
    end

    def normalize_japanese_preserve_case(value)
      value.to_s.unicode_normalize(:nfkc).strip
    rescue StandardError
      value.to_s.strip
    end

    def app_time_zone
      # Local structured AI parsing must use the user's/context timezone.
      # In Render, Rails Time.zone may be UTC; if we use UTC here, "15:00" appears as next-day 00:00 in Japan.
      raw_timezone = context_value(:timezone).to_s.strip
      zone = raw_timezone.present? ? Time.find_zone(raw_timezone) : nil

      raw_env_timezone = ENV['APP_TIMEZONE'].to_s.strip
      zone ||= raw_env_timezone.present? ? Time.find_zone(raw_env_timezone) : nil

      current_zone = Time.zone
      if zone.nil? && current_zone && !%w[UTC Etc/UTC].include?(current_zone.tzinfo.name)
        zone = current_zone
      end

      zone || Time.find_zone('Asia/Tokyo') || ActiveSupport::TimeZone['Asia/Tokyo']
    end

    def context_now
      raw = context_value(:now)
      parsed = raw.present? ? app_time_zone.parse(raw.to_s) : nil
      parsed || app_time_zone.now
    rescue StandardError
      app_time_zone.now
    end

    def context_value(key)
      @context[key] || @context[key.to_s]
    end

    def target_year_month(text, now)
      if text.include?('来月')
        target = now.to_date.next_month
        return [target.year, target.month]
      end

      return [now.year, now.month] if text.include?('今月')

      match = text.match(/(?<![0-9])(?<month>1[0-2]|0?[1-9])月/)
      return [nil, nil] unless match

      month = match[:month].to_i
      year = now.year
      year += 1 if month < now.month && !text.include?('今年')
      [year, month]
    end

    def target_weekdays(text)
      normalized = normalize_japanese(text)
      weekdays = []

      WEEKDAY_MAP.each do |token, weekday|
        next if token.length == 1

        weekdays << weekday if normalized.include?(token) && !weekdays.include?(weekday)
      end

      normalized.scan(/(?:毎週|隔週)\s*([月火水木金土日](?:[・･、,\/／と]?\s*[月火水木金土日])*)/) do |match|
        match.first.scan(/[月火水木金土日]/).each do |char|
          weekday = WEEKDAY_MAP[char]
          weekdays << weekday if weekday && !weekdays.include?(weekday)
        end
      end

      normalized.scan(/(?:\A|[\s　、,。と\/／・･週])([月火水木金土日])(?=$|[\s　、,。と\/／・･にを])/).each do |match|
        weekday = WEEKDAY_MAP[match.first]
        weekdays << weekday if weekday && !weekdays.include?(weekday)
      end

      weekdays
    end

    def dates_for_month_weekdays(year, month, weekdays, today)
      date = Date.new(year, month, 1)
      last = date.next_month
      dates = []

      while date < last
        dates << date if date >= today && weekdays.include?(date.wday)
        date += 1
      end

      dates
    end

    def secretary_labels(value)
      case value
      when Hash
        value.transform_values { |child| secretary_labels(child) }
      when Array
        value.map { |child| secretary_labels(child) }
      when String
        value.gsub('AIエージェント', 'AI秘書')
      else
        value
      end
    end

    def normalize_hash(value)
      hash = value.to_h
      hash.respond_to?(:deep_stringify_keys) ? hash.deep_stringify_keys : hash
    rescue StandardError
      {}
    end

    def integer_or_nil(value)
      Integer(value)
    rescue StandardError
      nil
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end
