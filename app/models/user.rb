class User < ApplicationRecord
  has_secure_password

  has_many :auth_tokens, dependent: :destroy

  before_validation :normalize_email

  validates :email, presence: true, uniqueness: true

  private
  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
