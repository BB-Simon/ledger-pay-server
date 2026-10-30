class CreateReconciliationResults < ActiveRecord::Migration[8.1]
  def change
    create_table :reconciliation_results do |t|
      t.references :reconciliation_run, null: false, foreign_key: true
      t.references :reconciliation_record, null: false, foreign_key: true
      t.string :provider_reference
      t.string :record_type
      t.string :status
      t.string :discrepancy_type
      t.bigint :expected_amount
      t.bigint :actual_amount
      t.string :currency
      t.jsonb :details

      t.timestamps
    end

    add_index :reconciliation_results,
      [ :reconciliation_run_id, :provider_reference ],
      unique: true,
      name: "idx_reconciliation_results_run_reference"
  end
end
