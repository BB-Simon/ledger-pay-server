module Api
  module V1
    module Auth
      class MeController < ApplicationController
        before_action :authenticate_user!

        def show
          render json: {
            user: {
              id: current_user.id,
              email: current_user.email,
              status: current_user.status,
              created_at: current_user.created_at,
              updated_at: current_user.updated_at
            }
          }
        end
      end
    end
  end
end
