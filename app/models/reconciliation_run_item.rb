class ReconciliationRunItem < ApplicationRecord
  belongs_to :reconciliation_run

  enum :status, {
    pending: "pending",
    processing: "processing",
    matched: "matched",
    discrepancy: "discrepancy",
    failed: "failed"
  }

  validates :record_type, inclusion: {
    in: %w[payment refund payout]
  }

  validates :internal_type, presence: true

  scope :unfinished, -> { where(status: %w[pending processing]) }
  scope :terminal, -> { where(status: %w[matched discrepancy failed]) }
end
