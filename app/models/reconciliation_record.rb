class ReconciliationRecord < ApplicationRecord
  enum :status, {
    matched: "matched",
    discrepancy: "discrepancy",
    unresolved: "unresolved"
  }

  enum :discrepancy_type, {
    missing_internal_record: "missing_internal_record",
    missing_provider_record: "missing_provider_record",
    amount_mismatch: "amount_mismatch",
    currency_mismatch: "currency_mismatch",
    status_mismatch: "status_mismatch"
  }, prefix: true

  validates :provider, presence: true
  validates :provider_reference, presence: true
  validates :record_type, presence: true
  validates :status, presence: true
end
