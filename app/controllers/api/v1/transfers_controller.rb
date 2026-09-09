module Api
    module V1
      class TransfersController < ApplicationController
        before_action :authenticate_user!

        def create
          from_wallet = current_user.wallets.find(params[:from_wallet_id])
          to_wallet = Wallet.find(params[:to_wallet_id])


          transaction = Ledger::IdempotentTransfer.call(
            user: current_user,
            from_wallet: from_wallet,
            to_wallet: to_wallet,
            amount: params[:amount].to_i,
            idempotency_key: request.headers["idempotency-key"]
          )

          render json: {
            id: transaction.id,
            reference: transaction.reference,
            status: transaction.status,
            transaction_type: transaction.transaction_type
          }, status: :created

        rescue ArgumentError => e
          render json: {
            error: e.message
          }, status: :unprocessable_entity
        end
      end
    end
end
