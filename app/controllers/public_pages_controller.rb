# frozen_string_literal: true

class PublicPagesController < ApplicationController
  skip_before_action :require_login!, only: %i[privacy terms account_deletion]

  def privacy
    @support_email = support_email
  end

  def terms; end

  def account_deletion
    @support_email = support_email
  end

  private

  def support_email
    ENV.fetch('SUPPORT_EMAIL', 'admin@example.com')
  end
end
