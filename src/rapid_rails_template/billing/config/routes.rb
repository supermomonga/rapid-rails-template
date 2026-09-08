Billing::Engine.routes.draw do
  scope '/billing' do
    root 'plans#index'
    resources :merchants, only: %i[index show], param: :public_id
    resources :plans, only: %i[index show]
  end
  scope '/account/billing', module: :account, as: :account do
    resources :subscriptions, only: %i[index show create] do
      post :authorize, on: :member
      post :cancel, on: :member
      get :cancellation, on: :member
    end
  end
  scope '/merchant/billing', module: :merchant, as: :merchant do
    root 'entry#show'
    resources :accounts, controller: 'merchant_accounts', only: %i[new create]
    resources :invitations, only: :index do
      post :accept, on: :member
      post :reject, on: :member
    end
    post :selection, to: 'entry#select'
    scope '/:merchant_id' do
      get '/', to: 'overview#show', as: :dashboard
      resource :profile, controller: 'merchant_accounts', only: %i[edit update]
      resources :payout_addresses, only: %i[index create update]
      resources :plans, only: %i[index new create edit update]
      resources :sales, only: %i[index show]
      resources :payments, only: :index
      resources :refund_records, only: :index
      resources :charges, only: [] do
        resources :refund_records, only: %i[new create]
      end
      resources :memberships, only: %i[index update destroy]
      resources :invitations, controller: 'member_invitations', only: %i[create destroy], as: :member_invitations
      resources :audit_entries, only: :index
      resource :closure, only: %i[show create]
    end
  end
  scope '/admin/billing', module: :admin, as: :admin do
    root 'overview#show'
    get 'chain_settings', to: 'overview#chains'
    resource :settings, only: %i[show update]
    resources :chains, only: %i[update] do
      post :deploy, on: :member
    end
    resources :merchants, only: %i[index show update]
    resources :subscriptions, only: %i[index show]
    resources :transactions, only: [] do
      post :recheck, on: :member
    end
  end
end
