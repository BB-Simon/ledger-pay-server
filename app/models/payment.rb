class Payment < ApplicationRecord
  belongs_to :user
  belongs_to :wallet
  belongs_to :currency

  enum :status, {
    pending: "pending",
    succeeded: "succeeded",
    failed: "failed",
    cancelled: "cancelled"
  }
  validates :amount, numericality: {
    only_integer: true,
    greater_than: 0
  }
  validates :provider, presence: true
end
