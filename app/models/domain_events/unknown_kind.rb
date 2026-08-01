# frozen_string_literal: true

module DomainEvents
  # Raised when a producer tries to record a kind that is not in DomainEvents::Kinds.
  # A dedicated error (not ArgumentError) so callers can rescue precisely and so the
  # message names the offending kind for the log.
  class UnknownKind < StandardError
    def initialize(kind)
      super("unknown domain-event kind: #{kind.inspect} — register it in DomainEvents::Kinds")
    end
  end
end
