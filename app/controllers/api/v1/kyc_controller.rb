module Api
  module V1
    class KycController < ApplicationController
      before_action :authenticate_user!

      def show
        kyc = current_user.kyc_profile

        render json: {
          kyc: {
            status: kyc.status,
            verification_level: kyc.verification_level,
            verified_at: kyc.verified_at
          }
        }
      end
    end
  end
end
