
module Reconciliation
  class RetryRunItem
    JOB_CLASSES = {
      "payment" => Reconciliation::PaymentJob,
      "refund" => Reconciliation::RefundJob,
      "payout" => Reconciliation::PayoutJob
    }.freeze

    def self.call(item:, user:, ip_address: nil, request_id: nil)
      run = item.reconciliation_run

      run.with_lock do
        item.reload

        raise ArgumentError, "Only failed items can be retried" unless item.failed?
        raise ArgumentError, "Run is already running" if run.running?

        item.update!(
          status: :pending,
          started_at: nil,
          completed_at: nil,
          error_class: nil,
          error_message: nil
        )

        run.update!(
          status: :running,
          completed_at: nil,
          error_message: nil
        )

        items = run.reconciliation_run_items

        run.update!(
          records_checked: items.where(status: %w[matched discrepancy]).count,
          matched_count: items.matched.count,
          discrepancy_count: items.discrepancy.count,
          failed_count: items.failed.count
        )
      end

      job_class = JOB_CLASSES.fetch(item.record_type)
      jid = job_class.perform_async(item.id)

      unless jid
        raise "Sidekiq did not enqueue the reconciliation item"
      end

      AuditLogs::Record.call(
        action: "reconciliation_item.retry_requested",
        auditable: item,
        user: user,
        metadata: {
          reconciliation_run_id: run.id,
          record_type: item.record_type,
          internal_id: item.internal_id,
          sidekiq_jid: jid
        },
        ip_address: ip_address,
        request_id: request_id
      )

      item.reload
    rescue StandardError
      # Do not silently swallow failures. The caller should receive
      # the error and log/report it.
      raise
    end
  end
end
