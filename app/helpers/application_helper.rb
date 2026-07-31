module ApplicationHelper
  def money_amount(amount_minor, currency: Current.tenant&.functional_currency || "INR")
    "#{currency} #{number_with_precision(amount_minor.to_i / 100.0, precision: 2, delimiter: ",")}"
  end

  def basis_points_percentage(basis_points)
    number_to_percentage(basis_points.to_i / 100.0, precision: 2, strip_insignificant_zeros: true)
  end

  def credit_note_reason_label(reason_code)
    {
      "value_reduction" => "Value reduction",
      "service_deficiency" => "Service deficiency",
      "return" => "Return",
      "other" => "Other"
    }.fetch(reason_code.to_s, reason_code.to_s.humanize)
  end

  def role_name
    current_role_assignment&.role_template&.name || "Member"
  end

  def delivery_state_label(state)
    {
      "not_sent" => "Not sent",
      "queued" => "Queued",
      "sending" => "Sending",
      "sent" => "Sent",
      "failed" => "Delivery failed"
    }.fetch(state, state.to_s.humanize)
  end

  def status_class(state)
    case state
    when "posted", "sent", "verified" then "status-badge status-badge--success"
    when "failed", "reversed" then "status-badge status-badge--danger"
    when "queued", "sending", "draft", "parked" then "status-badge status-badge--pending"
    else "status-badge"
    end
  end

  def navigation_class(*controllers)
    controllers.flatten.include?(controller_name) ? "app-nav__link app-nav__link--active" : "app-nav__link"
  end

  def browser_document_path(document)
    if %w[RC PY].include?(document.doc_type)
      settlement_path(document, tenant_route_options)
    elsif document.doc_type == "PB"
      purchase_bill_path(document, tenant_route_options)
    elsif document.doc_type == "CN"
      credit_note_path(document, tenant_route_options)
    elsif document.doc_type == "SI"
      sales_invoice_path(document, tenant_route_options)
    elsif document.doc_type == "OB"
      opening_balance_path(document, tenant_route_options)
    else
      journal_voucher_path(document, tenant_route_options)
    end
  end

  def settlement_kind_label(document_or_code)
    code = document_or_code.respond_to?(:doc_type) ? document_or_code.doc_type : document_or_code.to_s
    { "RC" => "Customer receipt", "PY" => "Vendor payment" }.fetch(code, code)
  end

  def age_bucket_label(bucket)
    {
      "current" => "Current (0 days)",
      "days_1_30" => "1–30 days",
      "days_31_60" => "31–60 days",
      "days_61_90" => "61–90 days",
      "days_91_plus" => "91+ days"
    }.fetch(bucket.to_s, bucket.to_s.humanize)
  end
end
