# frozen_string_literal: true

module Taxes
  module India
    # Tax Deducted at Source — India's statutory withholding on certain payments.
    #
    # This is the EFFECTIVE-DATED CORRECTNESS KERNEL of the TDS engine, deliberately built
    # as a separately verified unit. It answers one question precisely: for an assessable credit
    # or earlier payment under a given section/date, to a deductee with (or without) a PAN, after
    # prior assessable sums in the statutory accumulation window — how much tax must be withheld?
    #
    # What lives here (this slice):
    #   * Schedule  — the effective-dated statutory rate/threshold table + a date resolver.
    #   * Deduction — a pure calculator: rate + threshold + §206AA → withheld/net amounts.
    #   * (Pan lives one level up, in Taxes::India::Pan, as it is not TDS-specific.)
    #
    # The lifecycle layer now records bill/advance assessments, posts TDS Payable, and provides
    # Form 26Q/Form 16A structured reports. What remains deferred:
    #   * challan/remittance settlement of that liability by its statutory due date;
    #   * §197 lower/nil-deduction certificates (a tenant+deductee override of the schedule);
    #   * NSDL/TRACES upload/rendering and broader correction-statement semantics.
    #
    # STATUTORY-ACCURACY CAVEAT: the seeded rates/thresholds in Schedule reflect long-standing
    # values reviewed for the implemented effective windows. Rates and thresholds can change by
    # Finance Act / CBDT notification; the effective-dated shape exists precisely so a change is a
    # new row with a new window. Portal validation remains authoritative.
    module Tds
      # Raised when no schedule row covers a (section, category, date).
      UnknownSection = Class.new(ArgumentError)
      InvalidInput   = Class.new(ArgumentError)

      # The two-way rate split most sections use. A section whose rate does not depend on the
      # deductee's constitution uses :any and matches either caller category.
      DEDUCTEE_CATEGORIES = %i[individual_huf other any].freeze

      # §206AA higher rate when the deductee has no valid PAN: the greater of 20% and the
      # section rate. Expressed in basis points.
      NO_PAN_FLOOR_BASIS_POINTS = 2_000
    end
  end
end
