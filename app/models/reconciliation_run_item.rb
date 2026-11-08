class ReconciliationRunItem < ApplicationRecord
  TERMINAL_STATUSES = %w[matched discrepancy failed].freeze

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
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  # Terminal items are never reconciled again or overwritten.
  def terminal?
    status.in?(TERMINAL_STATUSES)
  end
end
