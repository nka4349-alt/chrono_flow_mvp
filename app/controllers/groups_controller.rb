# frozen_string_literal: true

class GroupsController < ApplicationController
  before_action :set_group, only: %i[edit update destroy reorder]

  # GET /groups (or root)
  # 左ツリー描画に使う: [{group:, depth:}, ...]
  def index
    @groups = build_group_tree
  end

  # GET /groups/new
  # 親を指定して作成できる
  def new
    @group = Group.new(parent_id: params[:parent_id])
    @groups = build_group_tree
  end

  # POST /groups
  def create
    @group = Group.new(group_params)

    if @group.save
      # 作成者を admin として登録（Devise等が無い環境でも落ちないようにガード）
      if respond_to?(:current_user) && current_user.present?
        GroupMember.find_or_create_by!(group: @group, user: current_user) do |gm|
          gm.role = :admin if gm.respond_to?(:role=)
        end
      end

      redirect_to root_path(group_id: @group.id), notice: 'グループを作成しました'
    else
      @groups = build_group_tree
      render :new, status: :unprocessable_entity
    end
  end

  # GET /groups/:id/edit
  def edit
    # 親候補を作る（自分自身・子孫は選べないよう除外）
    exclude_ids = @group.respond_to?(:subtree_ids) ? @group.subtree_ids : [@group.id]
    @groups = build_group_tree(nil, 0, exclude_ids: exclude_ids)

    # modal=1 の場合はモーダル用 partial を返す（任意）
    if params[:modal].present?
      render partial: 'groups/edit_modal', locals: { group: @group, groups: @groups }
    end
  end

  # PATCH/PUT /groups/:id
  def update
    if @group.update(group_params)
      redirect_to root_path(group_id: @group.id), notice: '更新しました'
    else
      exclude_ids = @group.respond_to?(:subtree_ids) ? @group.subtree_ids : [@group.id]
      @groups = build_group_tree(nil, 0, exclude_ids: exclude_ids)
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /groups/:id
  # NOTE: 子グループは親へ繰り上げ
  def destroy
    @group.children.update_all(parent_id: @group.parent_id)
    @group.destroy!
    redirect_to root_path, notice: '削除しました'
  end

  # PATCH /groups/:id/reorder
  def reorder
    @group.update(position: params[:position])
    head :ok
  end

  private

  def set_group
    @group = Group.find(params[:id])
  end

  def group_params
    params.require(:group).permit(:name, :parent_id, :position)
  end

  # Returns [{ group: Group, depth: Integer }, ...]
  # exclude_ids: 親候補から除外したい group.id の配列
  def build_group_tree(parent_id = nil, depth = 0, exclude_ids: [])
    groups = []
    scope = Group.where(parent_id: parent_id).order(:position, :id)
    scope = scope.where.not(id: exclude_ids) if exclude_ids.present?

    scope.each do |g|
      groups << { group: g, depth: depth }
      groups.concat(build_group_tree(g.id, depth + 1, exclude_ids: exclude_ids))
    end
    groups
  end
end
