# frozen_string_literal: true

class AddLocationAndColorToEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :events, :location, :string unless column_exists?(:events, :location)
    add_column :events, :color, :string unless column_exists?(:events, :color)
  end
end
