# frozen_string_literal: true

class AccountController < ApplicationController
  def delete
  end

  def destroy
    unless deletion_confirmed?
      @confirmation_error = '削除を続けるには DELETE と入力してください。'
      render :delete, status: :unprocessable_entity
      return
    end

    AccountDeletionService.call(current_user)
    reset_session
    redirect_to login_path, notice: 'アカウントを削除しました。ご利用ありがとうございました。'
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error("[account_deletion] #{e.class}: #{e.message}")
    @confirmation_error = '削除処理を完了できませんでした。時間をおいて再度お試しください。'
    render :delete, status: :internal_server_error
  end

  private

  def deletion_confirmed?
    params[:confirmation].to_s == 'DELETE'
  end
end
