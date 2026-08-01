# frozen_string_literal: true

module Taxes
  module India
    # Tax Deducted at Source — India's statutory withholding on certain payments.
    #
    # This is the EFFECTIVE-DATED CORRECTNESS KERNEL of the TDS engine, deliberately built
    # as a separately verified unit rather than folded into the completed purchase-bill path
    # (locked workplan, Batch 7). It answers one question precisely: for a payment under a
    # given section, on a given date, to a deductee with (or without) a PAN, having already
    # been paid some amount this financial year — how much tax must be withheld?
    #
    # What lives here (this slice):
    #   * Schedule  — the effective-dated statutory rate/threshold table + a date resolver.
    #   * Deduction — a pure calculator: rate + threshold + §206AA → withheld/net amounts.
    #   * (Pan lives one level up, in Taxes::India::Pan, as it is not TDS-specific.)
    #
    # What is DEFERRED to the TDS lifecycle slice (explicitly not built here):
    #   * recording a deduction against a source document and posting the "TDS Payable"
    #     liability into ledger_events;
    #   * challan/remittance settlement of that liability by its statutory due date;
    #   * quarterly return preparation (Form 26Q) and the deductee certificate (Form 16A);
    #   * §197 lower/nil-deduction certificates (a tenant+deductee override of the schedule);
    #   * correction/revision semantics.
    #
    # STATUTORY-ACCURACY CAVEAT: the seeded rates/thresholds in Schedule reflect long-standing
    # values as of authoring and are a preparation aid, not a filing determination. Rates and
    # thresholds change by Finance Act / CBDT notification; the effective-dated shape exists
    # precisely so a change is a new row with a new window, and every row must be reviewed
    # against the current notification before production filing. Same honesty posture as the
    # GST views ("preparation aids, not ITC-eligibility determinations").
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
