# config/routes.rb
# 既存の routes.rb に下記の resources :groups ブロックを反映してください。
# ※root はあなたのままでOKです。

resources :groups do
  member do
    patch :reorder
  end
end
