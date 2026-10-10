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
    attributes = {
      record_type: record_type,
      internal_type: internal&.class&.name,
      internal_id: internal&.id,
      expected_amount: expected_amount,
      actual_amount: actual_amount,
      currency: currency,
      status: status,
      discrepancy_type: discrepancy_type,
      details: details
    }

    record = ReconciliationRecord.create_or_find_by!(
      provider: provider,
      provider_reference: provider_reference
    ) do |new_record|
      new_record.assign_attributes(attributes)
    end

    record.update!(attributes)

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
