class IdempotencyKey < ApplicationRecord
  belongs_to :user
  belongs_to :ledger_transaction, class_name: "Transaction", optional: true

  validates :key, presence: true
  validates :request_hash, presence: true
  validates :status, presence: true
end
