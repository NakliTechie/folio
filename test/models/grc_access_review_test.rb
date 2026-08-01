# frozen_string_literal: true

require "test_helper"

class GrcAccessReviewTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "grc-owner@folio.invalid", password: "correct-horse-battery",
      org_name: "GRC Review"
    )
    @operator = invite_user("grc-operator@folio.invalid", "operator")
    @viewer = invite_user("grc-viewer@folio.invalid", "viewer")
  end

  test "the detector reports the governed rules per effective role assignment" do
    findings = Grc::Analyze.call(tenant: @org.tenant)
    owner = findings.select { |finding| finding.fetch("userId") == @org.user.id }
    operator = findings.select { |finding| finding.fetch("userId") == @operator.id }
    viewer = findings.select { |finding| finding.fetch("userId") == @viewer.id }

    assert_equal Grc::Rules::DEFAULTS.size, owner.size
    assert_equal [ "BILL_PAYMENT" ], operator.pluck("ruleCode")
    assert_empty viewer
    assert_equal "critical", operator.sole.fetch("severity")
    assert_equal({ "total" => 16, "critical" => 5, "high" => 9, "medium" => 2, "low" => 0 },
      Grc::Analyze.summary(findings))
  end

  test "an owner captures and attests immutable signed review evidence" do
    review = Grc::Reviews.capture!(tenant: @org.tenant, actor: @org.user)
    assert review.digest_valid?
    assert_equal 16, review.snapshot.dig("summary", "total")
    assert_equal 3, review.snapshot.fetch("assignments").size
    captured = DomainEvent.find(review.domain_event_id)
    assert_equal "access_review.captured", captured.action
    assert EventSigning.verify(captured)

    TeamRoles::Change.call!(
      tenant: @org.tenant, user: @operator, role_code: "viewer", actor: @org.user
    )
    assert_equal 16, review.reload.snapshot.dig("summary", "total"),
      "the historical review must not follow current role changes"

    attestation = Grc::Reviews.attest!(
      review: review, actor: @org.user, outcome: "remediation_required",
      notes: "Move payment execution away from the operator."
    )
    assert_equal "remediation_required", attestation.outcome
    assert EventSigning.verify(DomainEvent.find(attestation.domain_event_id))
    assert_raises(Grc::InvalidReview) do
      Grc::Reviews.attest!(
        review: review, actor: @org.user, outcome: "approved", notes: "Duplicate"
      )
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AccessReviewRun.transaction(requires_new: true) do
        review.update_column(:snapshot_sha256, "0" * 64)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AccessReviewAttestation.transaction(requires_new: true) do
        attestation.update_column(:notes, "Changed")
      end
    end
  end

  test "ordinary members cannot create review evidence" do
    error = assert_raises(Grc::InvalidReview) do
      Grc::Reviews.capture!(tenant: @org.tenant, actor: @operator)
    end
    assert_match(/Only an owner/, error.message)
    assert Authorization.permits?(
      user: @viewer, tenant_id: @org.tenant.id, capability: "grc.read"
    ) == false
  end

  private

  def invite_user(email, role_code)
    invitation = Onboarding::Invite.create!(
      tenant: @org.tenant, email: email, role_code: role_code, invited_by: @org.user
    )
    Onboarding::Invite.accept!(
      token: invitation.generate_token_for(:invite), password: "correct-horse-battery"
    )
  end
end
