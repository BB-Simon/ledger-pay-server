class Account < ApplicationRecord
  belongs_to :wallet
  belongs_to :currency

  has_many :ledger_entries, dependent: :restrict_with_error

  enum :account_type, {
    asset: "asset",
    liability: "liability",
    equity: "equity",
    revenue: "revenue",
    expense: "expense"
  }

  validates :status, presence: true
  validate :currency_must_match_wallet_currency

  private

  def currency_must_match_wallet_currency
    return unless wallet && currency

    if wallet.currency_id != currency_id
      errors.add(:currency, "must match the wallet's currency")
    end
  end
end
