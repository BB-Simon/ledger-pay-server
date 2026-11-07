class Wallet < ApplicationRecord
  belongs_to :user
  belongs_to :currency

  has_one :account, dependent: :restrict_with_error

  has_many :payments, dependent: :restrict_with_error

  has_many :refunds, through: :payments

  has_many :withdrawals, dependent: :restrict_with_error

  validates :status, presence: true

  def pending_withdrawal_amount
    withdrawals
      .where(status: :pending)
      .sum(:amount)
  end

  def pending_refund_amount
    refunds
      .where(status: :pending)
      .sum(:amount)
  end

  # Money that can be spent now: the ledger balance minus funds held for
  # pending withdrawals and pending refunds, which leave the wallet later.
  def available_balance
    account.balance - pending_withdrawal_amount - pending_refund_amount
  end
end
