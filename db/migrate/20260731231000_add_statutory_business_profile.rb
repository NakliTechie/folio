# frozen_string_literal: true

class AddStatutoryBusinessProfile < ActiveRecord::Migration[8.1]
  def change
    change_table :offices, bulk: true do |table|
      table.string :address_line1
      table.string :address_line2
      table.string :city
      table.string :postal_code
      table.string :state_code
      table.string :country_code, limit: 2
    end
  end
end
