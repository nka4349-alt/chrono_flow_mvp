# frozen_string_literal: true

Rails.application.routes.draw do
  root 'home#index'

  # Sessions
  get '/login',  to: 'sessions#new'
  post '/login', to: 'sessions#create'
  delete '/logout', to: 'sessions#destroy'
  get '/signup', to: 'users#new'
  post '/signup', to: 'users#create'
  get '/privacy', to: 'public_pages#privacy'
  get '/terms',   to: 'public_pages#terms'
  get '/account-deletion', to: 'public_pages#account_deletion'

  resources :problem_reports, only: %i[new create show]

  namespace :admin do
    root to: 'dashboard#index'
    resources :ai_usage_events, only: %i[index show]
    get 'ai_failures', to: 'ai_failures#index'
    resources :problem_reports, only: %i[index show update]
  end

  namespace :api do
    resources :users, only: %i[index]

    get  'ai_chat',           to: 'ai_chats#show'
    post 'ai_chat/messages',  to: 'ai_chats#create_message'
    post 'ai_chat/refresh',   to: 'ai_chats#refresh'
    post 'ai_recommendations/:id/accept_copy', to: 'ai_recommendations#accept_copy'
    post 'ai_recommendations/:id/feedback',    to: 'ai_recommendations#feedback'
    get 'ai_memories', to: 'ai_memories#index'
    delete 'user_places/:id', to: 'ai_memories#destroy_user_place'
    delete 'user_travel_routes/:id', to: 'ai_memories#destroy_user_travel_route'
    delete 'ai_user_preferences/:id', to: 'ai_memories#destroy_ai_user_preference'

    # Event share requests (approve flow)
    get  'event_share_requests',      to: 'event_share_requests#index'
    patch 'event_share_requests/:id', to: 'event_share_requests#update'
    post 'events/:event_id/share_requests', to: 'event_share_requests#create'

    # Personal calendar events (and shared/imported events)
    resources :events, only: %i[index show create update destroy] do
      member do
        post :share_to_groups
        post :add_to_my_calendar
      end

      resources :event_reminders, only: %i[index create], path: 'reminders'

      # Event chat (event_id provided)
      resources :chat_messages, only: %i[index create], controller: 'chat_messages'
    end

    resources :event_reminders, only: %i[destroy]

    resources :event_requests, only: %i[create update]

    resources :notifications, only: %i[index] do
      member do
        patch :read
      end
    end

    # Group tree + group calendar
    resources :groups, only: %i[index show create update destroy] do
      member do
        patch :reorder
        get :events
        get :members, to: 'group_members#index'
        post :invite_friends, to: 'group_members#invite_friends'
      end

      # role update
      patch 'members/:user_id/role', to: 'group_members#update_role'
      patch 'members/:user_id/owner', to: 'group_members#transfer_owner'

      # Group chat
      resources :chat_messages, only: %i[index create], controller: 'chat_messages'
    end

    resources :contacts, only: %i[index create update destroy] do
      collection do
        post :sync_friends
      end

      resources :availability_profiles, only: %i[index create update destroy]
    end

    # Friends + friend requests
    get 'friends', to: 'friends#index'
    get 'friend_requests', to: 'friends#requests'
    post 'friend_requests', to: 'friends#create_request'
    patch 'friend_requests/:id', to: 'friends#respond_request'

    # Direct (1:1) chat
    post 'direct_chats', to: 'direct_chats#create'
    get  'direct_chats/:id/chat_messages', to: 'direct_chat_messages#index'
    post 'direct_chats/:id/chat_messages', to: 'direct_chat_messages#create'
  end
end
