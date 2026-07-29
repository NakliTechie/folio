class Current < ActiveSupport::CurrentAttributes
  attribute :session, :tenant
  delegate :user, to: :session, allow_nil: true
end
