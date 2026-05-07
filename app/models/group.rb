# frozen_string_literal: true

class Group < ApplicationRecord
  belongs_to :parent, class_name: "Group", optional: true
  has_many :children, class_name: "Group", foreign_key: "parent_id", dependent: :nullify

  has_many :group_members, dependent: :destroy
  has_many :users, through: :group_members
  has_many :group_access_grants, dependent: :destroy

  has_many :ai_conversations, dependent: :destroy
  has_many :ai_recommendations, dependent: :nullify
  has_many :ai_policy_runs, dependent: :nullify
  has_many :ai_recommendation_impressions, dependent: :nullify

  # イベントは中間テーブル経由（eventsテーブルにgroup_idが無い前提）
  if defined?(EventGroup)
    has_many :event_groups, dependent: :destroy
    has_many :events, through: :event_groups
  end

  AI_CONTEXT_MODES = %w[personal_simple business_full].freeze
  INHERITANCE_MODES = %w[none parent_admin_only parent_free_busy tree_visible].freeze

  validates :name, presence: true
  validates :ai_context_mode, inclusion: { in: AI_CONTEXT_MODES }, if: -> { has_attribute?(:ai_context_mode) }
  validates :inheritance_mode, inclusion: { in: INHERITANCE_MODES }, if: -> { has_attribute?(:inheritance_mode) }
  validate :parent_cannot_be_self_or_descendant

  # 子孫ID（循環防止・親候補除外に使用）
  def descendant_ids
    children.flat_map { |c| [c.id] + c.descendant_ids }
  end

  def subtree_ids
    persisted? ? [id] + descendant_ids : []
  end

  private

  def parent_cannot_be_self_or_descendant
    return if parent_id.blank? || id.blank?

    if parent_id == id
      errors.add(:parent_id, "に自分自身は指定できません")
      return
    end

    if descendant_ids.include?(parent_id)
      errors.add(:parent_id, "に子孫グループは指定できません")
    end
  end
end
