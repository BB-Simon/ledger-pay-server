class KycProfile < ApplicationRecord
  belongs_to :user

  # Backed by a unique index on user_id (one profile per user).
  validates :user_id, uniqueness: true

  enum :status, {
    pending: "pending",
    verified: "verified",
    rejected: "rejected",
    under_review: "under_review"
  }
  validates :status, presence: true
end
