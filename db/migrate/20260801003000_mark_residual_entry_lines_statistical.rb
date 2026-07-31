# frozen_string_literal: true

class MarkResidualEntryLinesStatistical < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE entry_lines
      SET line_class = 'statistical'
      WHERE residual_of_line_id IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL
      UPDATE entry_lines
      SET line_class = 'real'
      WHERE residual_of_line_id IS NOT NULL
    SQL
  end
end
