# frozen_string_literal: true

# Seed a synthetic demo book through Folio's real engine.
#
#   bin/rails "sample_books:seed[consulting,owner@demo.test,a-long-demo-password]"
#   bin/rails sample_books:list
#
# Each run creates a FRESH tenant; re-running with the same email raises. Feeds
# /demo-nt, /walkthrough-nt, and manual exploration.
namespace :sample_books do
  desc "List available sample-book scenarios"
  task list: :environment do
    puts "Available scenarios:"
    Folio::SampleBooks::SCENARIOS.each_value do |s|
      puts format("  %-12s  %s (%d customers, %d sales)",
                  s.code, s.org_name, s.customers.size, s.sales.size)
    end
  end

  desc "Seed a sample book: sample_books:seed[scenario,email,password]"
  task :seed, %i[scenario email password] => :environment do |_t, args|
    abort "sample-book seeding is disabled in production" if Rails.env.production?

    scenario = args[:scenario].presence || "consulting"
    email = args[:email].presence || "owner@#{scenario}-demo.folio.invalid"
    password = args[:password].presence
    abort "pass an explicit password: sample_books:seed[scenario,email,password]" unless password

    result = Folio::SampleBooks.seed!(scenario: scenario, email: email, password: password)

    rupees = ->(minor) { format("₹%.2f", minor / 100.0) }
    puts "Seeded #{result.org_name} (scenario: #{result.scenario_code})"
    puts "  tenant_id : #{result.tenant_id}"
    puts "  login     : #{result.email} (use the password supplied to the task)"
    puts "  masters   : #{result.counts[:customers]} customers, #{result.counts[:vendors]} vendors, " \
         "#{result.counts[:services]} services"
    puts "  documents : #{result.counts[:sales]} invoices, #{result.counts[:purchases]} bills, " \
         "#{result.counts[:receipts]} receipts, #{result.counts[:payments]} payments"
    puts "  trial bal : #{result.balanced? ? 'TIED' : 'OUT OF BALANCE'} " \
         "(Dr #{rupees.call(result.trial_balance_debit_minor)} = Cr #{rupees.call(result.trial_balance_credit_minor)})"
    result.tds_previews.each do |p|
      status = p[:applied] ? "#{rupees.call(p[:tds_minor])} @ #{p[:rate_basis_points] / 100.0}%" : "none (below threshold)"
      puts "  TDS #{p[:section]} on #{p[:purchase]} (#{p[:vendor]}): #{status}"
    end
    puts "  TDS posted: #{result.tds_deductions_posted} deduction(s) withheld on vendor payments"
    abort "Trial balance did not tie — seed is inconsistent" unless result.balanced?
  end
end
