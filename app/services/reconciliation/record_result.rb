module Reconciliation
  # Stores a run's snapshot of one reconciliation outcome. A retry updates
  # the row, so the snapshot always shows the latest outcome.
  #
  # Run counters and status are not changed here: CompleteRunItem recomputes
  # them from the run's items.
  class RecordResult
    def self.call(run_id:, record:)
      run = ReconciliationRun.find(run_id)

      run.with_lock do
        result = run.reconciliation_results.find_or_initialize_by(
          provider_reference: record.provider_reference
        )

        result.update!(
          reconciliation_record: record,
          record_type: record.record_type,
          status: record.matched? ? :matched : :discrepancy,
          discrepancy_type: record.discrepancy_type,
          expected_amount: record.expected_amount,
          actual_amount: record.actual_amount,
          currency: record.currency,
          details: record.details || {}
        )

        result
      end
    end
  end
end
