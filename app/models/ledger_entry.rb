class LedgerEntry < ApplicationRecord
  belongs_to :account
  belongs_to :ledger_transaction, class_name: "Transaction"

  enum :entry_type, {
    debit: "debit",
    credit: "credit"
  }

  validates :entry_type, presence: true
  validates :amount, numericality: {
    only_integer: true,
    greater_than: 0
  }

  # Posted entries are immutable: ActiveRecord raises ReadOnlyRecord on any
  # update or destroy. Fix mistakes with a compensating transaction (see
  # Ledger::ReverseWithdrawal). Raw SQL (update_all, delete_all) isn't
  # blocked; that would need a database trigger (BUGS.md H12).
  def readonly?
    persisted? || super
  end
end
