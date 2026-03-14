# frozen_string_literal: true

class ApplicationController < ActionController::Base
  helper_method :current_user

  before_action :require_login!

  private

  def current_user
    return @current_user if defined?(@current_user)
    @current_user = User.find_by(id: session[:user_id])
  end

  def require_login!
    return if current_user.present?

    # API は JSON で返す（フロントは同一ドメインのCookieセッションで呼ぶ想定）
    if request.format.json? || request.path.start_with?('/api/')
      render json: { error: 'unauthorized' }, status: :unauthorized
    else
      redirect_to login_path
    end
  end

  def forbid!
    if request.format.json? || request.path.start_with?('/api/')
      render json: { error: 'forbidden' }, status: :forbidden
    else
      head :forbidden
    end
  end
end
