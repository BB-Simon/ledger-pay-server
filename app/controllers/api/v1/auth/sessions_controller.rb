require "securerandom"
require "digest"

module Api
  module V1
    module Auth
      class SessionsController < ApplicationController
        rate_limit to: 10, within: 1.minute, only: :create, with: -> { render_rate_limited }

        def create
          # Emails are stored stripped and downcased (User#normalize_email).
          user = User.find_by(email: params[:email].to_s.strip.downcase)

          # One message for every failure, so responses don't reveal which
          # emails exist or which accounts are suspended.
          unless user&.authenticate(params[:password].to_s) && user.status == "active"
            return render json: {
              error: "Invalid email or password"
            }, status: :unauthorized
          end

          raw_token = SecureRandom.hex(32)

          AuthToken.create!(
            user: user,
            token_digest: Digest::SHA256.hexdigest(raw_token),
            expires_at: 7.days.from_now
          )

          render json: {
            token: raw_token,
            user: {
              id: user.id,
              email: user.email,
              status: user.status
            }
          }
        end
      end
    end
  end
end
