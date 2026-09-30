class Wallet < ApplicationRecord
  belongs_to :user
  belongs_to :currency

  has_one :account, dependent: :restrict_with_error

  has_many :payments, dependent: :restrict_with_error

  has_many :withdrawals, dependent: :restrict_with_error

  validates :status, presence: true

  def pending_withdrawal_amount
    withdrawals
      .where(status: :pending)
      .sum(:amount)
  end

  def available_balance
    account.balance - pending_withdrawal_amount
  end
end
