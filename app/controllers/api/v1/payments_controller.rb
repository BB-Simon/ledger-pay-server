module Api
  module V1
    class PaymentsController < ApplicationController
      before_action :authenticate_user!

      def create
        wallet = current_user.wallets.find(params[:wallet_id])

        result = Payments::CreatePayment.call(
          user: current_user,
          wallet: wallet,
          amount: params[:amount].to_i,
        )

        payment = result[:payment]
        render json: {
          id: payment.id,
          amount: payment.amount,
          status: payment.status,
          currency: payment.currency.code,
          provider: payment.provider,
          client_secret: result[:client_secret]
        }, status: :created

      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
