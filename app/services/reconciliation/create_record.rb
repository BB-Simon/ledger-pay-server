module Reconciliation
  # Upserts the reconciliation record for one Stripe object. Records are
  # reused across runs, so an admin's resolution is kept only while the
  # same discrepancy keeps showing up.
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

      record.with_lock do
        previous = {
          discrepancy_type: record.discrepancy_type,
          resolved_by_id: record.resolved_by_id,
          resolution_notes: record.resolution_notes
        }

        record.assign_attributes(attributes)

        reopen = record.resolved? && record.discrepancy? &&
          (record.status_changed? || record.discrepancy_type_changed?)

        if reopen
          record.assign_attributes(
            resolution_status: :open,
            resolved_by: nil,
            resolved_at: nil,
            resolution_notes: nil
          )
        end

        # updated_at doubles as "last confirmed", which Run uses to skip
        # records it checked recently, so refresh it even when nothing changed.
        record.changed? ? record.save! : record.touch

        record_reopened(record, previous) if reopen
      end

      record
    end

    def self.record_reopened(record, previous)
      AuditLogs::Record.call(
        action: "reconciliation.reopened",
        auditable: record,
        metadata: {
          provider_reference: record.provider_reference,
          discrepancy_type: record.discrepancy_type,
          previous_discrepancy_type: previous[:discrepancy_type],
          previous_resolved_by_id: previous[:resolved_by_id],
          previous_resolution_notes: previous[:resolution_notes]
        }
      )
    end

    private_class_method :record_reopened
  end
end
