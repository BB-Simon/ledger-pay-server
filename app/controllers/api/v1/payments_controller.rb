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
        render json: payment_json(payment, result[:client_secret]),
          status: :created

      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def show
        payment = current_user.payments.find(params[:id])
        render json: payment_json(payment)
      end

      def create_refund
        payment = current_user.payments.find(params[:payment_id])

        result = Payments::CreateRefund.call(
          payment: payment,
          amount: params[:amount].to_i,
          reason: params[:reason]
        )

        refund = result[:refund]

        render json: refund_json(refund),
          status: :created

      rescue ArgumentError => e
        render json: { error: e.message },
          status: :unprocessable_entity
      rescue Stripe::StripeError => e
        render json: { error: e.message },
          status: :unprocessable_entity
      end

      private

      def payment_json(payment, client_secret = nil)
        {
          id: payment.id,
          amount: payment.amount,
          status: payment.status,
          currency: payment.currency.code,
          provider: payment.provider,
          provider_payment_id: payment.provider_payment_id,
          failure_code: payment.failure_code,
          failure_message: payment.failure_message,
          client_secret: client_secret
      }.compact
      end

      def refund_json(refund)
        {
          id: refund.id,
          payment_id: refund.payment_id,
          amount: refund.amount,
          currency: refund.payment.currency.code,
          provider: refund.provider,
          provider_refund_id: refund.provider_refund_id,
          status: refund.status,
          reason: refund.reason
        }.compact
      end
    end
  end
end
