Rails.application.routes.draw do
  resources :runs, only: :show do
    post :stop, on: :member
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
