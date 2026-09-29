module Api
  module V1
    class WithdrawalsController < ApplicationController
      before_action :authenticate_user!

      def create
        wallet = current_user.wallets.find(params[:wallet_id])

        withdrawal = Withdrawals::CreateWithdrawal.call(
          user: current_user,
          wallet: wallet,
          amount: params[:amount].to_i
        )

        render json: withdrawal_json(withdrawal),
          status: :created

      rescue ArgumentError => e
        render json: { error: e.message },
          status: :unprocessable_entity
      end

      private

      def withdrawal_json(withdrawal)
        {
          id: withdrawal.id,
          wallet_id: withdrawal.wallet_id,
          amount: withdrawal.amount,
          currency: withdrawal.currency.code,
          provider: withdrawal.provider,
          provider_withdrawal_id: withdrawal.provider_withdrawal_id,
          status: withdrawal.status,
          failure_code: withdrawal.failure_code,
          failure_message: withdrawal.failure_message
        }.compact
      end
    end
  end
end
