Billing::Engine.routes.draw do
  scope "/billing" do
    root "plans#index"
    resources :merchants, only: %i[index show], param: :public_id
    resources :plans, only: %i[index show]
  end
  scope "/account/billing", module: :account, as: :account do
    resources :subscriptions, only: %i[index show create] do
      post :authorize, on: :member
      post :cancel, on: :member
    end
    resource :merchant_profile, path: "merchant", only: %i[new create edit update]
    resources :payout_addresses, only: %i[create update]
    resources :plans, only: %i[index new create edit update]
    resources :sales, only: %i[index show]
    resources :charges, only: [] do
      resources :refund_records, only: :create
    end
  end
  scope "/admin/billing", module: :admin, as: :admin do
    root "overview#show"
    resource :settings, only: %i[show update]
    resources :chains, only: %i[update] do
      post :deploy, on: :member
    end
    resources :plans, only: %i[index new create edit update]
    resources :subscriptions, only: %i[index show]
    resources :charges, only: [] do
      resources :refund_records, only: :create
    end
    resources :transactions, only: [] do
      post :recheck, on: :member
    end
  end
end
