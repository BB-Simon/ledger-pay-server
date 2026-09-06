class KycProfile < ApplicationRecord
  belongs_to :user

  enum :status, {
    pending: "pending",
    verified: "verified",
    rejected: "rejected",
    under_review: "under_review"
  }
  validates :status, presence: true
end
