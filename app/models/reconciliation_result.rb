class ReconciliationResult < ApplicationRecord
  belongs_to :reconciliation_run
  belongs_to :reconciliation_record, optional: true

  enum :status, {
    # pending: "pending",
    matched: "matched",
    discrepancy: "discrepancy",
    failed: "failed"
  }

  validates :provider_reference, presence: true
  validates :record_type, presence: true
end
