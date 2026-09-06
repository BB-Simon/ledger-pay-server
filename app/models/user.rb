class User < ApplicationRecord
  has_secure_password

  validates :email, presence: true, uniqueness: true

  private
  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
