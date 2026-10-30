class AddFailedCountToReconciliationRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :reconciliation_runs, :failed_count, :integer, null: false, default: 0
  end
end
