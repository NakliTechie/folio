# frozen_string_literal: true

# Batch 6: IND AS 115 projections beneath the contract master. Commercial facts remain
# on contracts/domain_events; allocation, schedules, and posting runs are explicit so a
# contract never posts directly and every ledger effect can drill back to its judgement.
class CreateContractRevenueAccounting < ActiveRecord::Migration[8.1]
  def change
    create_performance_obligations
    create_milestones
    create_allocation_runs
    create_schedules
    create_posting_runs
  end

  private

  def create_performance_obligations
    create_table :contract_performance_obligations do |t|
      t.bigint :tenant_id, null: false
      t.references :contract, null: false, foreign_key: true
      t.integer :obligation_no, null: false
      t.string :description, null: false
      t.boolean :distinct, null: false, default: true
      t.boolean :series, null: false, default: false
      t.boolean :material_right, null: false, default: false
      t.string :satisfaction, null: false
      t.string :over_time_criterion
      t.string :progress_measure
      t.bigint :standalone_selling_price_minor, null: false
      t.string :ssp_method, null: false
      t.date :service_start_date
      t.date :service_end_date
      t.string :revenue_account_code, null: false, default: "4000"
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :contract_performance_obligations,
      %i[tenant_id contract_id obligation_no], unique: true,
      name: "index_contract_obligations_on_number"
    add_check_constraint :contract_performance_obligations,
      "obligation_no > 0", name: "contract_obligations_number_positive"
    add_check_constraint :contract_performance_obligations,
      "standalone_selling_price_minor >= 0", name: "contract_obligations_ssp_nonnegative"
    add_check_constraint :contract_performance_obligations,
      "satisfaction IN ('point_in_time', 'over_time')", name: "contract_obligations_satisfaction_valid"
  end

  def create_milestones
    create_table :contract_milestones do |t|
      t.bigint :tenant_id, null: false
      t.references :contract, null: false, foreign_key: true
      t.references :contract_performance_obligation, null: false, foreign_key: true,
        index: { name: "index_contract_milestones_on_obligation" }
      t.integer :milestone_no, null: false
      t.string :description, null: false
      t.date :planned_date, null: false
      t.date :achieved_date
      t.bigint :recognition_amount_minor, null: false
      t.boolean :triggers_billing, null: false, default: false
      t.boolean :triggers_recognition, null: false, default: true
      t.boolean :acceptance_required, null: false, default: false
      t.date :acceptance_date
      t.string :status, null: false, default: "planned"
      t.timestamps
    end
    add_index :contract_milestones,
      %i[tenant_id contract_performance_obligation_id milestone_no], unique: true,
      name: "index_contract_milestones_on_number"
    add_check_constraint :contract_milestones,
      "milestone_no > 0", name: "contract_milestones_number_positive"
    add_check_constraint :contract_milestones,
      "recognition_amount_minor >= 0", name: "contract_milestones_amount_nonnegative"
    add_check_constraint :contract_milestones,
      "status IN ('planned', 'achieved', 'cancelled')", name: "contract_milestones_status_valid"
  end

  def create_allocation_runs
    create_table :contract_allocation_runs do |t|
      t.bigint :tenant_id, null: false
      t.references :contract, null: false, foreign_key: true
      t.references :created_domain_event, null: false, foreign_key: { to_table: :domain_events }
      t.integer :version, null: false
      t.date :effective_date, null: false
      t.string :method, null: false, default: "relative_ssp"
      t.string :trigger, null: false, default: "initial"
      t.bigint :transaction_price_minor, null: false
      t.bigint :total_ssp_minor, null: false
      t.timestamps
    end
    add_index :contract_allocation_runs,
      %i[tenant_id contract_id version], unique: true,
      name: "index_contract_allocation_runs_on_version"
    add_check_constraint :contract_allocation_runs,
      "version > 0", name: "contract_allocation_runs_version_positive"
    add_check_constraint :contract_allocation_runs,
      "transaction_price_minor >= 0 AND total_ssp_minor > 0",
      name: "contract_allocation_runs_amounts_valid"
    add_check_constraint :contract_allocation_runs,
      "method IN ('relative_ssp')", name: "contract_allocation_runs_method_valid"

    create_table :contract_allocation_lines do |t|
      t.bigint :tenant_id, null: false
      t.references :contract_allocation_run, null: false, foreign_key: true,
        index: { name: "index_contract_allocation_lines_on_run" }
      t.references :contract_performance_obligation, null: false, foreign_key: true,
        index: { name: "index_contract_allocation_lines_on_obligation" }
      t.bigint :standalone_selling_price_minor, null: false
      t.decimal :allocation_ratio, precision: 20, scale: 12, null: false
      t.bigint :allocated_price_minor, null: false
      t.timestamps
    end
    add_index :contract_allocation_lines,
      %i[contract_allocation_run_id contract_performance_obligation_id], unique: true,
      name: "index_contract_allocation_lines_on_run_and_obligation"
    add_check_constraint :contract_allocation_lines,
      "standalone_selling_price_minor >= 0 AND allocated_price_minor >= 0",
      name: "contract_allocation_lines_amounts_nonnegative"
    add_check_constraint :contract_allocation_lines,
      "allocation_ratio >= 0 AND allocation_ratio <= 1",
      name: "contract_allocation_lines_ratio_valid"
  end

  def create_schedules
    create_table :contract_schedules do |t|
      t.bigint :tenant_id, null: false
      t.references :office, null: false, foreign_key: true
      t.references :contract, null: false, foreign_key: true
      t.references :contract_performance_obligation, null: false, foreign_key: true,
        index: { name: "index_contract_schedules_on_obligation" }
      t.references :contract_allocation_line, null: false, foreign_key: true,
        index: { name: "index_contract_schedules_on_allocation_line" }
      t.references :created_domain_event, null: false, foreign_key: { to_table: :domain_events }
      t.integer :version, null: false
      t.string :kind, null: false, default: "revenue"
      t.string :method, null: false
      t.string :accounting_principle, null: false, default: "ind_as"
      t.string :currency, null: false
      t.string :status, null: false, default: "current"
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :contract_schedules,
      %i[tenant_id contract_performance_obligation_id version], unique: true,
      name: "index_contract_schedules_on_version"
    add_index :contract_schedules,
      %i[tenant_id contract_id status], name: "index_contract_schedules_on_contract_status"
    add_check_constraint :contract_schedules,
      "version > 0", name: "contract_schedules_version_positive"
    add_check_constraint :contract_schedules,
      "kind IN ('revenue')", name: "contract_schedules_kind_valid"
    add_check_constraint :contract_schedules,
      "method IN ('straight_line', 'milestone')", name: "contract_schedules_method_valid"
    add_check_constraint :contract_schedules,
      "status IN ('current', 'superseded')", name: "contract_schedules_status_valid"

    create_table :contract_schedule_lines do |t|
      t.bigint :tenant_id, null: false
      t.references :contract_schedule, null: false, foreign_key: true
      t.references :contract_milestone, foreign_key: true
      t.integer :sequence, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.date :due_date, null: false
      t.date :original_effective_date, null: false
      t.bigint :amount_minor, null: false
      t.string :revenue_account_code, null: false
      t.string :status, null: false, default: "planned"
      t.references :posted_ledger_event, foreign_key: { to_table: :ledger_events }
      t.datetime :posted_at
      t.timestamps
    end
    add_index :contract_schedule_lines,
      %i[contract_schedule_id sequence], unique: true,
      name: "index_contract_schedule_lines_on_sequence"
    add_index :contract_schedule_lines, :posted_ledger_event_id, unique: true,
      where: "posted_ledger_event_id IS NOT NULL",
      name: "index_contract_schedule_lines_on_posted_event"
    add_index :contract_schedule_lines,
      %i[tenant_id due_date status], name: "index_contract_schedule_lines_due"
    add_check_constraint :contract_schedule_lines,
      "sequence > 0", name: "contract_schedule_lines_sequence_positive"
    add_check_constraint :contract_schedule_lines,
      "amount_minor >= 0", name: "contract_schedule_lines_amount_nonnegative"
    add_check_constraint :contract_schedule_lines,
      "period_end >= period_start", name: "contract_schedule_lines_period_valid"
    add_check_constraint :contract_schedule_lines,
      "status IN ('planned', 'posted', 'superseded')", name: "contract_schedule_lines_status_valid"
  end

  def create_posting_runs
    create_table :contract_posting_runs do |t|
      t.bigint :tenant_id, null: false
      t.references :office, null: false, foreign_key: true
      t.references :contract, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :idempotency_key, null: false
      t.string :run_type, null: false, default: "revenue_recognition"
      t.string :mode, null: false
      t.string :status, null: false, default: "pending"
      t.date :posting_date, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.jsonb :result, null: false, default: {}
      t.string :error_message
      t.timestamps
    end
    add_index :contract_posting_runs,
      %i[tenant_id idempotency_key], unique: true,
      name: "index_contract_posting_runs_on_idempotency"
    add_check_constraint :contract_posting_runs,
      "run_type IN ('revenue_recognition')", name: "contract_posting_runs_type_valid"
    add_check_constraint :contract_posting_runs,
      "mode IN ('simulate', 'post')", name: "contract_posting_runs_mode_valid"
    add_check_constraint :contract_posting_runs,
      "status IN ('pending', 'running', 'simulated', 'posted', 'failed')",
      name: "contract_posting_runs_status_valid"

    create_table :contract_posting_run_items do |t|
      t.bigint :tenant_id, null: false
      t.references :contract_posting_run, null: false, foreign_key: true,
        index: { name: "index_contract_posting_run_items_on_run" }
      t.references :contract_schedule_line, null: false, foreign_key: true,
        index: { name: "index_contract_posting_run_items_on_schedule_line" }
      t.string :status, null: false, default: "pending"
      t.references :ledger_event, foreign_key: true
      t.string :error_message
      t.timestamps
    end
    add_index :contract_posting_run_items,
      %i[contract_posting_run_id contract_schedule_line_id], unique: true,
      name: "index_contract_posting_run_items_on_run_and_line"
    add_check_constraint :contract_posting_run_items,
      "status IN ('pending', 'simulated', 'posted', 'skipped', 'failed')",
      name: "contract_posting_run_items_status_valid"
  end
end
