# frozen_string_literal: true

class CreateGrcAccessReviews < ActiveRecord::Migration[8.1]
  def up
    create_table :sod_conflict_rules do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.string :severity, null: false
      t.string :capability_a, null: false
      t.string :capability_b, null: false
      t.text :description, null: false
      t.text :remediation, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :sod_conflict_rules, %i[tenant_id code], unique: true
    add_check_constraint :sod_conflict_rules, "severity IN ('critical', 'high', 'medium', 'low')",
      name: "sod_conflict_rules_severity_valid"
    add_check_constraint :sod_conflict_rules, "capability_a <> capability_b",
      name: "sod_conflict_rules_capabilities_distinct"

    create_table :access_review_runs do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.bigint :domain_event_id, null: false
      t.jsonb :snapshot, null: false
      t.string :snapshot_sha256, null: false, limit: 64
      t.timestamps
    end
    add_index :access_review_runs, %i[tenant_id snapshot_sha256], unique: true

    create_table :access_review_attestations do |t|
      t.bigint :tenant_id, null: false
      t.references :access_review_run, null: false, foreign_key: true, index: { unique: true }
      t.references :attested_by, null: false, foreign_key: { to_table: :users }
      t.bigint :domain_event_id, null: false
      t.string :outcome, null: false
      t.text :notes, null: false
      t.timestamps
    end
    add_check_constraint :access_review_attestations,
      "outcome IN ('approved', 'remediation_required')",
      name: "access_review_attestations_outcome_valid"

    execute <<~SQL
      CREATE FUNCTION folio_access_review_evidence_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
      END;
      $$;
      CREATE TRIGGER access_review_runs_immutable
        BEFORE UPDATE OR DELETE ON access_review_runs
        FOR EACH ROW EXECUTE FUNCTION folio_access_review_evidence_immutable();
      CREATE TRIGGER access_review_attestations_immutable
        BEFORE UPDATE OR DELETE ON access_review_attestations
        FOR EACH ROW EXECUTE FUNCTION folio_access_review_evidence_immutable();
    SQL

    seed_permissions
    seed_rules
  end

  def down
    execute <<~SQL.squish
      DELETE FROM role_permissions WHERE capability IN ('grc.read', 'grc.manage')
    SQL
    execute <<~SQL
      DROP TRIGGER IF EXISTS access_review_attestations_immutable ON access_review_attestations;
      DROP TRIGGER IF EXISTS access_review_runs_immutable ON access_review_runs;
      DROP FUNCTION IF EXISTS folio_access_review_evidence_immutable();
    SQL
    drop_table :access_review_attestations
    drop_table :access_review_runs
    drop_table :sod_conflict_rules
  end

  private

  def seed_permissions
    execute <<~SQL.squish
      INSERT INTO role_permissions (role_template_id, capability, created_at, updated_at)
      SELECT role_templates.id, 'grc.read', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM role_templates
      WHERE role_templates.code IN ('accountant', 'ca_auditor')
        AND NOT EXISTS (
          SELECT 1 FROM role_permissions
          WHERE role_permissions.role_template_id = role_templates.id
            AND role_permissions.capability = 'grc.read'
        )
    SQL
  end

  def seed_rules
    values = Grc::Rules::DEFAULTS.map do |row|
      "(#{row.map { |value| connection.quote(value) }.join(', ')})"
    end.join(", ")
    execute <<~SQL.squish
      INSERT INTO sod_conflict_rules
        (tenant_id, code, name, severity, capability_a, capability_b, description, remediation,
         active, created_at, updated_at)
      SELECT tenants.id, rules.code, rules.name, rules.severity, rules.capability_a,
        rules.capability_b, rules.description, rules.remediation, TRUE,
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM tenants
      CROSS JOIN (VALUES #{values}) AS rules
        (code, name, severity, capability_a, capability_b, description, remediation)
    SQL
  end
end
