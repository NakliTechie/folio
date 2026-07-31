Rails.application.routes.draw do
  root "home#show"
  resources :accounts, only: %i[index new create edit update] do
    member do
      patch :deactivate
      patch :reactivate
    end
  end
  resources :journal_vouchers, path: "transactions", only: %i[index show new create] do
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
  get "reports/profit-and-loss", to: "reports#profit_and_loss", as: :profit_and_loss_report
  get "reports/balance-sheet", to: "reports#balance_sheet", as: :balance_sheet_report
  resource :reports, only: :show, controller: :reports
  resource :team, only: :show, controller: :team
  namespace :api do
    namespace :v1 do
      get "tenant", to: "tenants#show"
      resources :accounts, only: %i[index show create update]
      resources :document_types, only: :index
      get "reports/trial_balance", to: "reports#trial_balance"
      get "reports/account_type_totals", to: "reports#account_type_totals"
      get "reports/profit_and_loss", to: "reports#profit_and_loss"
      get "reports/balance_sheet", to: "reports#balance_sheet"
      resources :documents, only: %i[show create] do
        member do
          post :simulate
          post :post
          post :reverse
        end
      end
    end
  end
  resource :registration, only: %i[new create]
  get "verify/:token", to: "registrations#verify", as: :verify_email
  resource :verification_delivery, only: :create
  resources :invitations, only: :create do
    post :resend, on: :member
  end
  get "invitations/:token/accept", to: "invitations#accept", as: :accept_invitation
  post "invitations/:token/accept", to: "invitations#do_accept"
  resource :security, only: :show, controller: :security
  resources :active_sessions, only: :destroy
  resource :session
  resources :passwords, param: :token, only: %i[new create edit update]
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "favicon.ico", to: redirect("/icon.png")

  # Defines the root path route ("/")
  # root "posts#index"
end
