#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
TARGET="$ROOT/app/controllers/api/groups_controller.rb"

if [ ! -f "$TARGET" ]; then
  echo "[ERR] not found: $TARGET"
  exit 1
fi

if grep -q "CF_GROUPS_CREATE_FIX_500_V1" "$TARGET"; then
  echo "Already patched (marker found)."
  exit 0
fi

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="$TARGET.bak_${TS}"
cp "$TARGET" "$BACKUP"
echo "Backed up: $BACKUP"

cat >> "$TARGET" <<'RUBY'

# === CF_GROUPS_CREATE_FIX_500_V1 ===
# Fix HTTP 500 when creating/updating groups from JS modal.
# - Accepts both {group:{...}} and top-level JSON payloads
# - Returns 422 with message on validation errors instead of 500
# - Ensures current_user becomes GroupMember admin on new group (if model exists)
# - Prevents cyclic parent assignment on update
module Api
  class GroupsController < BaseController
    # Some older versions accidentally ran set_group/authorize before create.
    skip_before_action :set_group, only: %i[create], raise: false
    skip_before_action :authorize_member!, only: %i[create], raise: false
    skip_before_action :authorize_admin!,  only: %i[create], raise: false

    def create
      attrs = group_params

      group = Group.new(attrs)
      # normalize blanks
      group.parent_id = nil if group.respond_to?(:parent_id) && group.parent_id.blank?

      # auto position if column exists and not provided
      if group.has_attribute?(:position) && group.position.nil?
        group.position = next_position_for_parent(group.parent_id)
      end

      # set creator columns if they exist (schema differs between variants)
      %i[owner_id created_by_id creator_id user_id].each do |col|
        next unless group.has_attribute?(col)
        group.public_send("#{col}=", current_user.id) if group.public_send(col).nil?
      end

      group.save!

      # ensure current user becomes admin member
      begin
        gm = GroupMember.find_or_initialize_by(group: group, user: current_user)
        gm.role = :admin if gm.respond_to?(:role=)
        gm.save!
      rescue NameError
        # GroupMember model not present in some variants
      end

      render json: { group: serialize_group(group) }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end

    def update
      group = defined?(@group) && @group ? @group : Group.find(params[:id])

      attrs = group_params
      # normalize blanks
      attrs[:parent_id] = nil if attrs.key?(:parent_id) && attrs[:parent_id].blank?

      # prevent cycles: cannot set parent to self or descendants
      if attrs.key?(:parent_id) && attrs[:parent_id].present?
        pid = attrs[:parent_id].to_i
        if pid == group.id || descendant_ids(group).include?(pid)
          return render json: { error: "親グループが不正です（循環参照）" }, status: :unprocessable_entity
        end
      end

      group.update!(attrs)
      render json: { group: serialize_group(group) }
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end

    private

    def group_params
      source = params[:group].presence || params
      source = source.is_a?(ActionController::Parameters) ? source : ActionController::Parameters.new(source)
      source.permit(:name, :parent_id, :position)
    end

    def serialize_group(g)
      h = { id: g.id, name: g.name }
      h[:parent_id] = g.parent_id if g.respond_to?(:parent_id)
      h[:position]  = g.position  if g.respond_to?(:position)
      h
    end

    def next_position_for_parent(parent_id)
      return 0 unless Group.column_names.include?("position")
      scope = Group.all
      if Group.column_names.include?("parent_id")
        scope = parent_id.nil? ? scope.where(parent_id: nil) : scope.where(parent_id: parent_id)
      end
      (scope.maximum(:position) || -1) + 1
    end

    def descendant_ids(group)
      return [] unless Group.column_names.include?("parent_id")
      ids = []
      queue = [group.id]
      while queue.any?
        children = Group.where(parent_id: queue).pluck(:id)
        queue = children
        ids.concat(children)
      end
      ids
    end
  end
end
# === END CF_GROUPS_CREATE_FIX_500_V1 ===

RUBY

echo "OK: appended create/update override to $TARGET"
echo "Next: restart Rails server (Ctrl+C -> bin/rails s) and hard reload browser (Ctrl+Shift+R)."
