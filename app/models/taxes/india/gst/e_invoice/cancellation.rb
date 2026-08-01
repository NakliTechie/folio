# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        module Cancellation
          REASONS = { "1" => "Duplicate", "2" => "Data entry mistake" }.freeze
          WINDOW = 24.hours
          MAX_REMARKS_LENGTH = 100

          module_function

          def eligible_until(submission)
            submission.acknowledged_at + WINDOW if submission.acknowledged_at
          end
        end
      end
    end
  end
end
