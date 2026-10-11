module Reconciliation
  class ResolveRecord
    def self.call(record:, admin:, notes:)
      new(
        record: record,
        admin: admin,
        notes: notes
      ).call
    end

    def initialize(record:, admin:, notes:)
      @record = record
      @admin = admin
      @notes = notes
    end

    def call
      raise ArgumentError, "Admin access required" unless @admin.admin?

      raise ArgumentError, "Record is not a discrepancy" unless
        @record.discrepancy?

      raise ArgumentError, "Record is already resolved" if
        @record.resolved?

      raise ArgumentError, "Resolution notes are required" if
        @notes.blank?

      ReconciliationRecord.transaction do
        @record.lock!

        raise ArgumentError, "Record is already resolved" if
          @record.resolved?

        @record.update!(
          resolution_status: :resolved,
          resolved_by: @admin,
          resolved_at: Time.current,
          resolution_notes: @notes
        )

        AuditLogs::Record.call(
          action: "reconciliation.resolved",
          auditable: @record,
          user: @admin,
          metadata: {
            discrepancy_type: @record.discrepancy_type,
            provider_reference: @record.provider_reference,
            resolution_notes: @notes
          }
        )
      end

      @record
    end
  end
end
