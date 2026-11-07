module Withdrawals
  class CreateWithdrawal
    def self.call(user:, wallet:, amount:)
      new(
        user: user,
        wallet: wallet,
        amount: amount
      ).call
    end

    def initialize(user:, wallet:, amount:)
      @user = user
      @wallet = wallet
      @amount = amount
    end

    def call
      validate!

      withdrawal = Wallet.transaction do
        wallet = Wallet.find(@wallet.id)
        raise ArgumentError, "Wallet account is required" unless wallet.account

        # Lock the wallet's ledger account, the same row Ledger::Transfer locks,
        # so withdrawals and transfers from one wallet run one at a time.
        wallet.account.lock!

        validate_wallet_balance!(wallet)

        Withdrawal.create!(
          user: @user,
          wallet: wallet,
          amount: @amount,
          currency: wallet.currency,
          provider: "stripe",
          status: :pending
        )
      end

      AuditLogs::Record.call(
        action: "withdrawal.created",
        auditable: withdrawal,
        user: @user,
        metadata: {
          amount: withdrawal.amount,
          currency: withdrawal.currency.code
        }
      )

      submit_to_stripe(withdrawal)

      withdrawal.reload
    end

    # A definite Stripe rejection raises (the withdrawal is already marked
    # failed) and the controller returns 422. An unknown outcome keeps the
    # withdrawal pending and retries in the background with the same key.
    def submit_to_stripe(withdrawal)
      Withdrawals::CreateProviderWithdrawal.call(withdrawal: withdrawal)
    rescue *StripeErrors::DEFINITE_FAILURES
      raise
    rescue Stripe::StripeError => e
      Rails.logger.warn("Withdrawal #{withdrawal.id} submission outcome unknown, retrying: #{e.class}: #{e.message}")
      Withdrawals::SubmitWithdrawalJob.perform_async(withdrawal.id)
    end

    private

    def validate!
      raise ArgumentError, "Amount must be a positive integer" unless
        @amount.is_a?(Integer) && @amount > 0

      raise ArgumentError, "Wallet must be active" unless
        @wallet.status == "active"

      raise ArgumentError, "Wallet must belong to user" unless
        @wallet.user_id == @user.id
    end

    def validate_wallet_balance!(wallet)
      raise ArgumentError, "Insufficient wallet balance" unless
        wallet.available_balance >= @amount
    end
  end
end
