# frozen_string_literal: true

require "test_helper"

class TaxesIndiaTest < ActiveSupport::TestCase
  test "GSTIN validation checks structure state and the mod-36 check character" do
    assert Taxes::India::Gstin.valid?("27AAPFU0939F1ZV")
    assert Taxes::India::Gstin.valid?("29AAAAA0300L1Z8")
    assert_equal "27", Taxes::India::Gstin.state_code("27aapfu0939f1zv")

    refute Taxes::India::Gstin.valid?("27AAPFU0939F1ZZ")
    refute Taxes::India::Gstin.valid?("25AAPFU0939F1ZV")
    refute Taxes::India::Gstin.valid?("not-a-gstin")
  end

  test "ordinary intra-state supply splits GST into equal central and state components" do
    result = Taxes::India::Adapter.calculate(
      taxable_minor: 100_00,
      rate_basis_points: 1800,
      supplier_state_code: "27",
      place_of_supply_state_code: "27"
    )

    assert_equal :intra_state, result.nature
    assert_equal({ cgst: 900, sgst: 900 }, result.components)
    assert_equal 1800, result.total_tax_minor
  end

  test "an odd intra-state rate is rejected before a draft can freeze it" do
    error = assert_raises(Taxes::InvalidTaxInput) do
      Taxes::India::Adapter.calculate(
        taxable_minor: 100_00,
        rate_basis_points: 501,
        supplier_state_code: "27",
        place_of_supply_state_code: "27"
      )
    end

    assert_match(/split exactly/, error.message)
  end

  test "ordinary inter-state supply uses IGST and preserves cess separately" do
    result = Taxes::India::Adapter.calculate(
      taxable_minor: 100_00,
      rate_basis_points: 1800,
      cess_rate_basis_points: 100,
      supplier_state_code: "27",
      place_of_supply_state_code: "29"
    )

    assert_equal :inter_state, result.nature
    assert_equal({ igst: 1800, cess: 100 }, result.components)
    assert_equal 1900, result.total_tax_minor
  end

  test "an intra-state supply in a union territory uses UTGST" do
    result = Taxes::India::Adapter.calculate(
      taxable_minor: 100_00,
      rate_basis_points: 500,
      supplier_state_code: "04",
      place_of_supply_state_code: "04"
    )

    assert_equal({ cgst: 250, utgst: 250 }, result.components)
  end

  test "an intra-Puducherry supply uses SGST because Puducherry has a legislature" do
    result = Taxes::India::Adapter.calculate(
      taxable_minor: 100_00,
      rate_basis_points: 500,
      supplier_state_code: "34",
      place_of_supply_state_code: "34"
    )

    assert_equal({ cgst: 250, sgst: 250 }, result.components)
    refute Taxes::India::StateCodes.union_territory_without_legislature?("34")
  end

  test "the central UTGST jurisdiction set stays explicit" do
    assert_equal %w[04 26 31 35 38],
      Taxes::India::StateCodes::UNION_TERRITORIES_WITHOUT_LEGISLATURE
  end

  test "the jurisdiction registry selects adapters without a posting-core country branch" do
    india = Entity.new(jurisdiction_profile: "IN")
    result = Taxes.calculate(
      entity: india,
      taxable_minor: 100_00,
      rate_basis_points: 1800,
      supplier_state_code: "27",
      place_of_supply_state_code: "29"
    )
    assert_equal({ igst: 1800 }, result.components)

    germany = Entity.new(jurisdiction_profile: "DE")
    assert_raises(Taxes::UnsupportedJurisdiction) do
      Taxes.calculate(
        entity: germany,
        taxable_minor: 100_00,
        rate_basis_points: 1900,
        supplier_state_code: "27",
        place_of_supply_state_code: "29"
      )
    end
  end

  test "tax inputs fail closed instead of being coerced" do
    error = assert_raises(Taxes::InvalidTaxInput) do
      Taxes::India::Adapter.calculate(
        taxable_minor: "10000",
        rate_basis_points: 1800,
        supplier_state_code: "27",
        place_of_supply_state_code: "29"
      )
    end
    assert_match(/taxable_minor/, error.message)
  end
end
