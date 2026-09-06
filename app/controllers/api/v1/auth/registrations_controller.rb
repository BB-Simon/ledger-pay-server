module Api
  module V1
    module Auth
      class RegistrationsController < ApplicationController
        def create
          user = User.new(user_params)

          if user.save
            user.create_kyc_profile!(status: "pending")
            render json: {
              user: {
                id: user.id,
                email: user.email,
                status: user.status
              }
            }, status: :created
          else
            render json: {
              errors: user.errors.full_messages
            }, status: :unprocessable_entity
          end
        end


        private

        def user_params
          params.permit(:email, :password)
        end
      end
    end
  end
end
