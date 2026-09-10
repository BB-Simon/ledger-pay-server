class WebhookEvent < ApplicationRecord
  enum :status, {
    pending: "pending",
    processed: "processed",
    failed: "failed"
  }

  validates :provider, presence: true
  validates :event_id, presence: true
  validates :event_type, presence: true

  validates :payload, presence: true
end
