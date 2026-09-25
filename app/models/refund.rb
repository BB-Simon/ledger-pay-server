class Refund < ApplicationRecord
  belongs_to :payment

  enum :status, {
    pending: "pending",
    succeeded: "succeeded",
    failed: "failed",
    canceled: "canceled"
  }

  validates :amount, numericality: {
    only_integer: true,
    greater_than: 0
  }

  validates :provider, presence: true
end
