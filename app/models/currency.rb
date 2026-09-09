class Currency < ApplicationRecord
  has_many :wallets, dependent: :restrict_with_error

  has_many :payments, dependent: :restrict_with_error

  before_validation :normalize_code

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :decimal_places, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0
  }


  private
  def normalize_code
    self.code = code.to_s.strip.upcase
  end
end
