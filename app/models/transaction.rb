class Transaction < ApplicationRecord
  belongs_to :currency

  has_one :idempotency_key, dependent: :nullify
  has_many :ledger_entries, foreign_key: :ledger_transaction_id, dependent: :restrict_with_error

  enum :transaction_type, {
    deposit: "deposit",
    withdrawal: "withdrawal",
    transfer: "transfer",
    refund: "refund",
    fee: "fee"
  }

  enum :status, {
    pending: "pending",
    posted: "posted",
    failed: "failed",
    reversed: "reversed"
  }

  validates :reference, presence: true, uniqueness: true
end
