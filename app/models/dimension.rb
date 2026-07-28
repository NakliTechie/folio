# frozen_string_literal: true

# The dimension registry (hybrid model). Committed dimensions are real typed columns on
# entry_lines; uncommitted ones live in entry_lines.extra and are never aggregated in a
# statutory report. The registry governs derivation, requiredness and validation only.
class Dimension < ApplicationRecord
  VALUE_TYPES = %w[reference text enum].freeze
  validates :tenant_id, :code, :label, :value_type, presence: true
  validates :value_type, inclusion: { in: VALUE_TYPES }
end
