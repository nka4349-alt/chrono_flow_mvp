# frozen_string_literal: true

class EnsureDisplayFieldsOnEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :events, :location, :string unless column_exists?(:events, :location)
    add_column :events, :color, :string, default: '#3b82f6', null: false unless column_exists?(:events, :color)
    add_column :events, :description, :text unless column_exists?(:events, :description)
  end
end
