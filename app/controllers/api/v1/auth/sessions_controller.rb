require "securerandom"
require "digest"

module Api
  module V1
    module Auth
      class SessionsController < ApplicationController
        def create
          user = User.find_by(email: params[:email.to_s.strip.downcase])

          unless user&.authenticate(params[:password])
            render json: {
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
