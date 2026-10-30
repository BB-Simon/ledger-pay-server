
module Reconciliation
  class RecordResult
    def self.call(run_id:, record:)
      run = ReconciliationRun.find(run_id)

      run.with_lock do
        # A retry must not create or count the same result twice.
        existing = run.reconciliation_results.find_by(
          provider_reference: record.provider_reference
        )

        return existing if existing

        result = run.reconciliation_results.create!(
          reconciliation_record: record,
          provider_reference: record.provider_reference,
          record_type: record.record_type,
          status: record.matched? ? :matched : :discrepancy,
          discrepancy_type: record.discrepancy_type,
          expected_amount: record.expected_amount,
          actual_amount: record.actual_amount,
          currency: record.currency,
          details: record.details || {}
        )

        run.update!(
          records_checked: run.records_checked + 1,
          matched_count: run.matched_count + (result.matched? ? 1 : 0),
          discrepancy_count: run.discrepancy_count +
            (result.discrepancy? ? 1 : 0)
        )

        if run.records_checked >= run.total_items
          run.update!(
            status: :completed,
            completed_at: Time.current
          )
        end

        terminal_count = run.records_checked + run.failed_count

        if terminal_count >= run.total_items
          run.update!(
            status: run.failed_count.positive? ? :failed : :completed,
            completed_at: Time.current
          )
        end

        result
      end
    end
  end
end
