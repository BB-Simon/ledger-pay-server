class Payment < ApplicationRecord
  belongs_to :user
  belongs_to :wallet
  belongs_to :currency

  has_many :refunds, dependent: :restrict_with_error

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

  def refunded_amount
    refunds
      .where(status: [ :pending, :succeeded ])
      .sum(:amount)
  end

  def refundable_amount
    amount - refunded_amount
  end
end
