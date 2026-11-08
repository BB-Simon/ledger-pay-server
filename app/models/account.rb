class Account < ApplicationRecord
  belongs_to :wallet, optional: true
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
  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validate :currency_must_match_wallet_currency

  # Summed in the database, so the cost doesn't grow with entries loaded
  # into Ruby (this runs while account rows are locked).
  def balance
    totals = ledger_entries.group(:entry_type).sum(:amount)
    debits = totals.fetch("debit", 0)
    credits = totals.fetch("credit", 0)

    increses_with_debit? ? debits - credits : credits - debits
  end

  private

  def increses_with_debit?
    asset?  || expense?
  end

  def currency_must_match_wallet_currency
    return unless wallet && currency

    if wallet.currency_id != currency_id
      errors.add(:currency, "must match the wallet's currency")
    end
  end
end
