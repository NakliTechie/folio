# frozen_string_literal: true

require "digest"

module Grc
  module Reviews
    OUTCOMES = %w[approved remediation_required].freeze

    module_function

    def capture!(tenant:, actor:)
      authorize!(tenant, actor)
      findings = Grc::Analyze.call(tenant: tenant)
      snapshot = {
        "formatVersion" => 1,
        "tenantId" => tenant.id,
        "asOf" => Time.current.iso8601(6),
        "assignments" => Grc::Analyze.assignment_snapshot(tenant: tenant),
        "findings" => findings,
        "summary" => Grc::Analyze.summary(findings)
      }
      digest = Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(snapshot))
      AccessReviewRun.transaction do
        event = DomainEvents::Record.call(
          tenant_id: tenant.id, kind: "access_review.captured", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: digest,
          payload: { "snapshotSha256" => digest, "summary" => snapshot.fetch("summary") }
        )
        AccessReviewRun.create!(
          tenant_id: tenant.id, created_by: actor, domain_event_id: event.id,
          snapshot: snapshot, snapshot_sha256: digest
        )
      end
    end

    def attest!(review:, actor:, outcome:, notes:)
      authorize!(review.tenant, actor)
      selected = outcome.to_s
      explanation = notes.to_s.strip
      raise InvalidReview, "Choose an attestation outcome" unless OUTCOMES.include?(selected)
      raise InvalidReview, "Attestation notes are required" if explanation.blank?
      raise InvalidReview, "The captured access-review snapshot no longer verifies" unless review.digest_valid?

      AccessReviewAttestation.transaction do
        review.lock!
        raise InvalidReview, "This access review is already attested" if review.access_review_attestation
        event = DomainEvents::Record.call(
          tenant_id: review.tenant_id, kind: "access_review.attested", actor: "u:#{actor.id}",
          actor_user_id: actor.id, ref: review.id.to_s,
          payload: {
            "accessReviewRunId" => review.id, "snapshotSha256" => review.snapshot_sha256,
            "outcome" => selected, "notes" => explanation
          }
        )
        AccessReviewAttestation.create!(
          tenant_id: review.tenant_id, access_review_run: review, attested_by: actor,
          domain_event_id: event.id, outcome: selected, notes: explanation
        )
      end
    end

    def authorize!(tenant, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: tenant.id, capability: "grc.manage"
      )

      raise InvalidReview, "Only an owner can capture or attest an access review"
    end
  end
end
