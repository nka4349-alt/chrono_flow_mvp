# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login!, only: %i[new create]

  def new
  end

  def create
    email = params[:email].to_s.strip.downcase
    user = User.find_by(email: email)

    if user&.authenticate(params[:password].to_s)
      reset_session
      session[:user_id] = user.id
      redirect_to root_path
    else
      flash.now[:alert] = 'メールアドレスまたはパスワードが違います'
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path
  end
end
