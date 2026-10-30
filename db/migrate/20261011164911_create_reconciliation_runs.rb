class CreateReconciliationRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :reconciliation_runs do |t|
      t.string :provider, null: false
      t.string :run_type, null: false
      t.string :status, null: false, default: "pending"

      t.datetime :started_at
      t.datetime :completed_at

      t.integer :records_checked, null: false, default: 0
      t.integer :matched_count, null: false, default: 0
      t.integer :discrepancy_count, null: false, default: 0

      t.text :error_message

      t.timestamps
    end

    add_index :reconciliation_runs, [ :provider, :created_at ]
    add_index :reconciliation_runs, :status
  end
end
