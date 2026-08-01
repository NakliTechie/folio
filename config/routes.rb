Rails.application.routes.draw do
  root "home#show"
  resources :accounts, only: %i[index new create edit update] do
    member do
      patch :deactivate
      patch :reactivate
    end
  end
  resources :parties, only: %i[index new create edit update] do
    member do
      patch :deactivate
      patch :reactivate
    end
  end
  resources :items, only: %i[index new create edit update] do
    member do
      patch :deactivate
      patch :reactivate
    end
  end
  resources :tax_registrations, path: "tax-registrations", only: %i[index new create edit update] do
    member do
      patch :deactivate
      patch :reactivate
    end
  end
  resource :business_profile, path: "company-details", only: %i[edit update]
  resources :journal_vouchers, path: "transactions", only: %i[index show new create edit update destroy] do
    member do
      post :post
      post :reverse
    end
  end
  resources :opening_balances, path: "opening-balances", only: %i[index show new create] do
    member do
      post :post
      post :reverse
    end
  end
  resources :sales_invoices, path: "sales-invoices", only: %i[index show new create] do
    member do
      get :print
      get :einvoice_json
      post :prepare_einvoice
      post :post
      post :reverse
    end
  end
  resources :credit_notes, path: "credit-notes", only: %i[index show new create] do
    member do
      get :print
      post :post
    end
  end
  resources :purchase_bills, path: "purchase-bills", only: %i[index show new create destroy] do
    member do
      post :post
      post :reverse
    end
  end
  resources :purchase_credit_notes, path: "purchase-credit-notes", only: %i[index show new create destroy] do
    post :post, on: :member
  end
  resources :purchase_debit_notes, path: "purchase-debit-notes", only: %i[index show new create destroy] do
    post :post, on: :member
  end
  resources :settlements, path: "cash", only: %i[index show new create] do
    post :post, on: :member
  end
  post "cash/:id/allocations/:allocation_id/reset", to: "settlements#reset_allocation",
    as: :reset_settlement_allocation
  get "cash/:id/allocations/:allocation_id/reallocate", to: "settlements#new_reallocation",
    as: :new_settlement_reallocation
  post "cash/:id/allocations/:allocation_id/reallocate", to: "settlements#reallocate",
    as: :settlement_reallocation
  post "open-item-credits/net", to: "open_item_credits#net", as: :net_open_item_credit
  post "open-item-credits/refund", to: "open_item_credits#refund", as: :refund_open_item_credit
  get "reports/profit-and-loss", to: "reports#profit_and_loss", as: :profit_and_loss_report
  get "reports/balance-sheet", to: "reports#balance_sheet", as: :balance_sheet_report
  get "reports/aged-receivables", to: "reports#aged_receivables", as: :aged_receivables_report
  get "reports/aged-payables", to: "reports#aged_payables", as: :aged_payables_report
  get "reports/party-ledger", to: "reports#party_ledger", as: :party_ledger_report
  get "reports/day-book", to: "reports#day_book", as: :day_book_report
  get "reports/gst-summary", to: "reports#gst_summary", as: :gst_summary_report
  get "reports/gst-summary/gstr1.json", to: "reports#gstr1_filing", as: :gstr1_filing_report
  resource :period_close, path: "period-close", only: %i[show update]
  resource :reports, only: :show, controller: :reports
  resource :team, only: :show, controller: :team
  patch "team/roles/:user_id", to: "team#update_role", as: :update_team_role
  namespace :api do
    namespace :v1 do
      get "tenant", to: "tenants#show"
      resources :accounts, only: %i[index show create update]
      resources :parties, only: %i[index show create update]
      resources :items, only: %i[index show create update]
      resources :tax_registrations, only: %i[index show create update]
      resource :business_profile, only: %i[show update]
      resources :document_types, only: :index
      get "reports/trial_balance", to: "reports#trial_balance"
      get "reports/account_type_totals", to: "reports#account_type_totals"
      get "reports/profit_and_loss", to: "reports#profit_and_loss"
      get "reports/balance_sheet", to: "reports#balance_sheet"
      get "reports/aged_receivables", to: "reports#aged_receivables"
      get "reports/aged_payables", to: "reports#aged_payables"
      get "reports/party_ledger", to: "reports#party_ledger"
      get "reports/day_book", to: "reports#day_book"
      get "reports/gst_summary", to: "reports#gst_summary"
      post "reports/gst_filing", to: "reports#gst_filing"
      resource :period_close, only: %i[show update]
      resources :documents, only: %i[show create] do
        member do
          post :simulate
          post :post
          post :reverse
        end
      end
      resources :sales_invoices, only: %i[index show create] do
        member do
          post :prepare_einvoice
          post :post
          post :reverse
        end
      end
      resources :credit_notes, only: %i[index show create] do
        post :post, on: :member
      end
      resources :purchase_bills, only: %i[index show create destroy] do
        member do
          post :post
          post :reverse
        end
      end
      resources :purchase_credit_notes, only: %i[index show create destroy] do
        post :post, on: :member
      end
      resources :purchase_debit_notes, only: %i[index show create destroy] do
        post :post, on: :member
      end
      resources :settlements, only: %i[index show create] do
        post :post, on: :member
      end
      post "settlements/:id/allocations/:allocation_id/reset", to: "settlements#reset"
      post "settlements/:id/allocations/:allocation_id/reallocate", to: "settlements#reallocate"
      post "open_item_credits/net", to: "open_item_credits#net"
      post "open_item_credits/refund", to: "open_item_credits#refund"
    end
  end
  resource :registration, only: %i[new create]
  get "verify", to: "registrations#verify", as: :verify_email
  post "verify", to: "registrations#confirm_verification", as: :confirm_email_verification
  resource :verification_delivery, only: :create
  resources :invitations, only: :create do
    post :resend, on: :member
  end
  get "invitations/accept", to: "invitations#accept", as: :accept_invitation
  post "invitations/accept", to: "invitations#do_accept"
  resource :security, only: :show, controller: :security
  resources :active_sessions, only: :destroy
  resource :session
  resource :password, only: %i[new create edit update]
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "ready" => "readiness#show", as: :readiness
  get "favicon.ico", to: redirect("/icon.png")

  # Defines the root path route ("/")
  # root "posts#index"
end
