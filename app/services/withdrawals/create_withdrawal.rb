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
        wallet = Wallet.lock.find(@wallet.id)

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

      withdrawal
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
