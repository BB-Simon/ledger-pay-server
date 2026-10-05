module Reconciliation
  class CreateRecord
    def self.call(
      provider:,
      provider_reference:,
      record_type:,
      internal: nil,
      expected_amount: nil,
      actual_amount: nil,
      currency: nil,
      status:,
      discrepancy_type: nil,
      details: {}
    )
    record = ReconciliationRecord.find_or_initialize_by(
      provider: provider,
      provider_reference: provider_reference
    )

    record.assign_attributes(
      record_type: record_type,
      internal_type: internal&.class&.name,
      internal_id: internal&.id,
      expected_amount: expected_amount,
      actual_amount: actual_amount,
      currency: currency,
      status: status,
      discrepancy_type: discrepancy_type,
      details: details
    )

    record.save!

    record


      # ReconciliationRecord.create!(
      #   provider: provider,
      #   provider_reference: provider_reference,
      #   record_type: record_type,
      #   internal_type: internal&.class&.name,
      #   internal_id: internal&.id,
      #   expected_amount: expected_amount,
      #   actual_amount: actual_amount,
      #   currency: currency,
      #   status: status,
      #   discrepancy_type: discrepancy_type,
      #   details: details
      # )
    end
  end
end
