class Wallet < ApplicationRecord
  belongs_to :user
  belongs_to :currency

  has_one :account, dependent: :restrict_with_error

  validates :status, presence: true
end
