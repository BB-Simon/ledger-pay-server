class Wallet < ApplicationRecord
  belongs_to :user
  belongs_to :currency

  validates :status, presence: true
end
