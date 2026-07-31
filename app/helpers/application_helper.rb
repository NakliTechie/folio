module ApplicationHelper
  def money_amount(amount_minor, currency: Current.tenant&.functional_currency || "INR")
    "#{currency} #{number_with_precision(amount_minor.to_i / 100.0, precision: 2, delimiter: ",")}"
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

  def navigation_class(controller)
    controller_name == controller ? "app-nav__link app-nav__link--active" : "app-nav__link"
  end

  def browser_document_path(document)
    if document.doc_type == "OB"
      opening_balance_path(document, tenant_route_options)
    else
      journal_voucher_path(document, tenant_route_options)
    end
  end
end
