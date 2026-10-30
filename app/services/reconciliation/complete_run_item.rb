
module Reconciliation
  class CompleteRunItem
    TERMINAL_STATUSES = %w[matched discrepancy failed].freeze

    def self.call(item_id:, status:, error: nil)
      unless TERMINAL_STATUSES.include?(status.to_s)
        raise ArgumentError, "Invalid terminal status: #{status}"
      end

      item = ReconciliationRunItem.find(item_id)
      run = item.reconciliation_run

      run.with_lock do
        item.reload

        # A retry must not overwrite a previously completed result.
        return item if item.terminal?

        item.update!(
          status: status,
          completed_at: Time.current,
          error_class: error&.class&.name,
          error_message: error&.message&.to_s&.truncate(1000)
        )

        refresh_run_counts!(run)
      end

      item.reload
    end

    def self.refresh_run_counts!(run)
      items = run.reconciliation_run_items

      checked = items.where(status: %w[matched discrepancy]).count
      failed = items.failed.count
      total = items.count
      terminal = checked + failed

      run.update!(
        total_items: total,
        records_checked: checked,
        matched_count: items.matched.count,
        discrepancy_count: items.discrepancy.count,
        failed_count: failed,
        status: if terminal == total
                  failed.positive? ? :failed : :completed
                else
                  :running
                end,
        completed_at: terminal == total ? Time.current : nil
      )
    end

    private_class_method :refresh_run_counts!
  end
end
