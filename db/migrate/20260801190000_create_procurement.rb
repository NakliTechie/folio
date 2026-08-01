# frozen_string_literal: true

# Batch 9: vendor authorization and commitment-rightward procurement. Purchase orders
# are non-financial domain events; goods receipts post inventory/GRNI; bill matches are
# advisory evidence so an exception is visible without preventing legitimate AP posting.
class CreateProcurement < ActiveRecord::Migration[8.1]
  def up
    now = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO accounts (tenant_id, code, name, account_type, active, monetary, created_at, updated_at)
      SELECT tenants.id, '2050', 'Goods Received Not Invoiced', 'liability', TRUE, TRUE, #{now}, #{now}
      FROM tenants
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts WHERE accounts.tenant_id = tenants.id AND accounts.code = '2050'
      )
    SQL

    create_table :vendor_profiles do |t|
      t.bigint :tenant_id, null: false
      t.references :party, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.boolean :spend_authorized, null: false, default: false
      t.boolean :purchasing_hold, null: false, default: false
      t.boolean :posting_hold, null: false, default: false
      t.boolean :payment_hold, null: false, default: false
      t.integer :payment_terms_days, null: false, default: 30
      t.string :preferred_currency, null: false
      t.datetime :approved_at
      t.timestamps
    end
    add_index :vendor_profiles, %i[tenant_id party_id], unique: true
    add_check_constraint :vendor_profiles, "status IN ('pending', 'approved', 'suspended')",
      name: "vendor_profiles_status_valid"
    add_check_constraint :vendor_profiles, "payment_terms_days >= 0",
      name: "vendor_profiles_terms_nonnegative"
    add_check_constraint :vendor_profiles,
      "(status = 'approved' AND spend_authorized = TRUE AND approved_by_id IS NOT NULL " \
      "AND approved_at IS NOT NULL) OR (status <> 'approved' AND spend_authorized = FALSE)",
      name: "vendor_profiles_approval_coherent"

    create_table :purchase_order_number_ranges do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.integer :fiscal_year, null: false
      t.integer :next_value, null: false, default: 1
      t.timestamps
    end
    add_index :purchase_order_number_ranges, %i[tenant_id entity_id office_id fiscal_year],
      unique: true, name: "index_purchase_order_ranges_on_series"
    add_check_constraint :purchase_order_number_ranges, "next_value > 0",
      name: "purchase_order_ranges_next_positive"

    create_table :purchase_orders do |t|
      t.bigint :tenant_id, null: false
      t.references :entity, null: false, foreign_key: true
      t.references :office, null: false, foreign_key: true
      t.references :vendor_profile, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :order_number, null: false
      t.integer :fiscal_year, null: false
      t.string :status, null: false, default: "draft"
      t.date :order_date, null: false
      t.date :expected_on
      t.string :currency, null: false
      t.integer :minor_unit_exponent, null: false
      t.bigint :subtotal_minor, null: false
      t.text :description
      t.datetime :approved_at
      t.date :closed_on
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :purchase_orders, %i[tenant_id order_number], unique: true
    add_index :purchase_orders, %i[tenant_id status order_date]
    add_check_constraint :purchase_orders,
      "status IN ('draft', 'approved', 'partially_received', 'received', 'closed')",
      name: "purchase_orders_status_valid"
    add_check_constraint :purchase_orders, "subtotal_minor > 0",
      name: "purchase_orders_subtotal_positive"

    create_table :purchase_order_lines do |t|
      t.bigint :tenant_id, null: false
      t.references :purchase_order, null: false, foreign_key: true
      t.references :item, null: false, foreign_key: true
      t.references :warehouse, foreign_key: true
      t.integer :line_no, null: false
      t.string :description, null: false
      t.decimal :ordered_quantity, precision: 20, scale: 6, null: false
      t.decimal :received_quantity, precision: 20, scale: 6, null: false, default: 0
      t.bigint :unit_price_minor, null: false
      t.bigint :line_total_minor, null: false
      t.string :account_code, null: false
      t.string :item_type, null: false
      t.jsonb :item_snapshot, null: false, default: {}
      t.timestamps
    end
    add_index :purchase_order_lines, %i[purchase_order_id line_no], unique: true
    add_index :purchase_order_lines, %i[purchase_order_id item_id], unique: true,
      name: "index_purchase_order_lines_on_unique_item"
    add_check_constraint :purchase_order_lines, "ordered_quantity > 0",
      name: "purchase_order_lines_quantity_positive"
    add_check_constraint :purchase_order_lines,
      "received_quantity >= 0 AND received_quantity <= ordered_quantity",
      name: "purchase_order_lines_received_coherent"
    add_check_constraint :purchase_order_lines, "unit_price_minor >= 0 AND line_total_minor > 0",
      name: "purchase_order_lines_value_valid"
    add_check_constraint :purchase_order_lines, "item_type IN ('service', 'good')",
      name: "purchase_order_lines_item_type_valid"

    create_table :goods_receipts do |t|
      t.bigint :tenant_id, null: false
      t.references :purchase_order, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :receipt_number, null: false
      t.string :idempotency_key, null: false
      t.string :request_sha256, null: false
      t.date :received_on, null: false
      t.string :external_reference
      t.timestamps
    end
    add_index :goods_receipts, %i[tenant_id receipt_number], unique: true
    add_index :goods_receipts, %i[tenant_id idempotency_key], unique: true

    create_table :goods_receipt_lines do |t|
      t.bigint :tenant_id, null: false
      t.references :goods_receipt, null: false, foreign_key: true
      t.references :purchase_order_line, null: false, foreign_key: true
      t.references :inventory_transaction, foreign_key: true
      t.decimal :received_quantity, precision: 20, scale: 6, null: false
      t.timestamps
    end
    add_index :goods_receipt_lines, %i[goods_receipt_id purchase_order_line_id], unique: true,
      name: "index_goods_receipt_lines_on_order_line"
    add_check_constraint :goods_receipt_lines, "received_quantity > 0",
      name: "goods_receipt_lines_quantity_positive"

    add_reference :documents, :purchase_order, foreign_key: true
    add_reference :document_lines, :purchase_order_line, foreign_key: true

    create_table :procurement_matches do |t|
      t.bigint :tenant_id, null: false
      t.references :document, null: false, foreign_key: true
      t.references :document_line, null: false, foreign_key: true, index: false
      t.references :purchase_order, null: false, foreign_key: true
      t.references :purchase_order_line, null: false, foreign_key: true
      t.string :status, null: false
      t.decimal :billed_quantity, precision: 20, scale: 6, null: false
      t.bigint :ordered_unit_price_minor, null: false
      t.bigint :billed_unit_price_minor, null: false
      t.jsonb :exceptions, null: false, default: []
      t.timestamps
    end
    add_index :procurement_matches, :document_line_id, unique: true
    add_check_constraint :procurement_matches, "status IN ('matched', 'exception')",
      name: "procurement_matches_status_valid"
    add_check_constraint :procurement_matches, "billed_quantity > 0",
      name: "procurement_matches_quantity_positive"

    execute <<~SQL
      CREATE FUNCTION folio_procurement_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;

      CREATE TRIGGER goods_receipts_immutable
        BEFORE UPDATE OR DELETE ON goods_receipts
        FOR EACH ROW EXECUTE FUNCTION folio_procurement_evidence_immutable();
      CREATE TRIGGER goods_receipt_lines_immutable
        BEFORE UPDATE OR DELETE ON goods_receipt_lines
        FOR EACH ROW EXECUTE FUNCTION folio_procurement_evidence_immutable();
    SQL

    seed_permissions
  end

  def down
    execute <<~SQL.squish
      DELETE FROM role_permissions
      WHERE capability IN (
        'procurement.read', 'procurement.manage', 'procurement.approve', 'procurement.receive'
      )
    SQL
    execute <<~SQL
      DROP TRIGGER IF EXISTS goods_receipt_lines_immutable ON goods_receipt_lines;
      DROP TRIGGER IF EXISTS goods_receipts_immutable ON goods_receipts;
      DROP FUNCTION IF EXISTS folio_procurement_evidence_immutable();
    SQL
    drop_table :procurement_matches
    remove_reference :document_lines, :purchase_order_line
    remove_reference :documents, :purchase_order
    drop_table :goods_receipt_lines
    drop_table :goods_receipts
    drop_table :purchase_order_lines
    drop_table :purchase_orders
    drop_table :purchase_order_number_ranges
    drop_table :vendor_profiles
  end

  private

  def seed_permissions
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, capabilities.capability, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      CROSS JOIN (VALUES
        ('procurement.read'), ('procurement.manage'), ('procurement.approve'), ('procurement.receive')
      ) AS capabilities(capability)
      WHERE role_templates.code = 'accountant'
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = capabilities.capability
        )
    SQL
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'procurement.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('operator', 'ca_auditor', 'viewer')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'procurement.read'
        )
    SQL
  end
end
