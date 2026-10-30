class CreateReconciliationRunItems < ActiveRecord::Migration[8.1]
  def change
    create_table :reconciliation_run_items do |t|
      t.references :reconciliation_run, null: false, foreign_key: true
      t.string :record_type, null: false
      t.string :internal_type, null: false
      t.bigint :internal_id
      t.string :provider_reference
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.datetime :started_at
      t.datetime :completed_at
      t.string :error_class
      t.text :error_message

      t.timestamps
    end

    add_index :reconciliation_run_items,
      [ :reconciliation_run_id, :record_type, :internal_type, :internal_id ],
      unique: true,
      name: "idx_reconciliation_run_items_unique_item"

    add_index :reconciliation_run_items, :status
  end
end
