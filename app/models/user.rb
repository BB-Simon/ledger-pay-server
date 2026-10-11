class User < ApplicationRecord
  has_secure_password

  has_many :auth_tokens, dependent: :destroy
  has_one :kyc_profile, dependent: :destroy
  has_many :wallets, dependent: :restrict_with_error

  has_many :payments, dependent: :restrict_with_error

  has_many :idempotency_key, dependent: :restrict_with_error

  has_many :withdrawals, dependent: :restrict_with_error

  before_validation :normalize_email

  enum :role, {
    customer: "customer",
    admin: "admin",
    compliance_officer: "compliance_officer",
    finance_officer: "finance_officer",
    support_agent: "support_agent",
    system: "system"
  }, default: :customer

  validates :email, presence: true, uniqueness: true


  private
  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
