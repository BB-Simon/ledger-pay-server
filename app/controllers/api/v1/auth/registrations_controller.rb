module Api
  module V1
    module Auth
      class RegistrationsController < ApplicationController
        rate_limit to: 10, within: 1.minute, only: :create, with: -> { render_rate_limited }

        def create
          user = User.new(user_params)

          # The user, KYC profile and wallet are created together or not at all.
          User.transaction do
            user.save!
            user.create_kyc_profile!(status: "pending")
            Wallets::Open.call(user: user)
          end

          render json: {
            user: {
              id: user.id,
              email: user.email,
              status: user.status
            }
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          errors = user.errors.full_messages.presence || e.record.errors.full_messages
          render json: { errors: errors }, status: :unprocessable_entity
        end

        private

        def user_params
          params.permit(:email, :password)
        end
      end
    end
  end
end
