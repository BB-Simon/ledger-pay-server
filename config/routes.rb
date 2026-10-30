Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html
  namespace :api do
    namespace :v1 do
      namespace :auth do
        post "register", to: "registrations#create"
        post "login", to: "sessions#create"
      end

      namespace :webhooks do
        post "stripe", to: "stripe#create"
      end

      namespace :admin do
        resources :reconciliation_records, only: [ :index, :show ]
        post "reconciliation_records/:id/resolve", to: "reconciliation_records#resolve"
        resources :reconciliation_runs, only: %i[index show] do
          post "items/:item_id/retry",
            to: "reconciliation_runs#retry_item",
            on: :member,
            as: :retry_item
        end
      end


      get "me", to: "me#show"
      get "kyc", to: "kyc#show"
      post "transfers", to: "transfers#create"
      get "withdrawals", to: "withdrawals#index"
      get "withdrawals/:id", to: "withdrawals#show"
      post "wallets/:wallet_id/withdrawals", to: "withdrawals#create"
      post "payments", to: "payments#create"
      get "payments/:id", to: "payments#show"
      get "payments/:payment_id/refunds", to: "payments#refunds"
      post "payments/:payment_id/refunds", to: "payments#create_refund"
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
end
