# frozen_string_literal: true

Rails.application.routes.draw do
  root 'home#index'

  # Sessions
  get '/login',  to: 'sessions#new'
  post '/login', to: 'sessions#create'
  delete '/logout', to: 'sessions#destroy'
  get '/signup', to: 'users#new'
  post '/signup', to: 'users#create'

  namespace :api do
    resources :users, only: %i[index]

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

      # Event chat (event_id provided)
      resources :chat_messages, only: %i[index create], controller: 'chat_messages'
    end

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

      # Group chat
      resources :chat_messages, only: %i[index create], controller: 'chat_messages'
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
