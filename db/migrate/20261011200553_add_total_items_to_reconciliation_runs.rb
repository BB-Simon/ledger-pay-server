class AddTotalItemsToReconciliationRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :reconciliation_runs, :total_items, :integer, null: false, default: 0
  end
end
