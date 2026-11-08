class Transaction < ApplicationRecord
  belongs_to :currency

  # No `dependent:` options: transactions are read-only once posted (see
  # readonly? below), so they're never destroyed.
  has_one :idempotency_key, foreign_key: :ledger_transaction_id, inverse_of: :ledger_transaction
  has_many :ledger_entries, foreign_key: :ledger_transaction_id, inverse_of: :ledger_transaction

  enum :transaction_type, {
    deposit: "deposit",
    withdrawal: "withdrawal",
    transfer: "transfer",
    refund: "refund",
    fee: "fee",
    reversal: "reversal"
  }

  enum :status, {
    pending: "pending",
    posted: "posted",
    failed: "failed"
  }

  validates :reference, presence: true, uniqueness: true

  # Posted transactions are immutable: ActiveRecord raises ReadOnlyRecord on
  # any update or destroy. Fix mistakes with a compensating transaction (see
  # Ledger::ReverseWithdrawal). Raw SQL (update_all, delete_all) isn't
  # blocked; that would need a database trigger (BUGS.md H12).
  def readonly?
    persisted? || super
  end
end
