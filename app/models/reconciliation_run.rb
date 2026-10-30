class ReconciliationRun < ApplicationRecord
  has_many :reconciliation_results,
    dependent: :restrict_with_error

  has_many :reconciliation_run_items,
    dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, default: :pending

  validates :provider, presence: true
  validates :run_type, presence: true
end
