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
end
