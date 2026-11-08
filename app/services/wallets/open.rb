module Wallets
  # Opens a wallet with its ledger account, so it can take payments right
  # away. Wallet accounts are liabilities: money the platform owes the user.
  class Open
    DEFAULT_CURRENCY = "USD".freeze

    def self.call(user:, currency_code: DEFAULT_CURRENCY)
      new(user: user, currency_code: currency_code).call
    end

    def initialize(user:, currency_code:)
      @user = user
      @currency_code = currency_code
    end

    def call
      # Seeded by db/seeds.rb. A missing currency is a setup problem, not a
      # client error, so it isn't an ArgumentError.
      currency = Currency.find_by(code: @currency_code) ||
        raise("Currency #{@currency_code} is missing; run bin/rails db:seed")

      Wallet.transaction do
        wallet = @user.wallets.create!(currency: currency, status: "active")

        Account.create!(
          wallet: wallet,
          currency: currency,
          account_type: :liability,
          code: "WALLET_#{wallet.id}_#{currency.code}",
          name: "Wallet #{wallet.id} #{currency.code}",
          status: "active"
        )

        wallet
      end
    end
  end
end
