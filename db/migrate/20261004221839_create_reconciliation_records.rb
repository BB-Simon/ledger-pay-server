class CreateReconciliationRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :reconciliation_records do |t|
      t.string :provider
      t.string :provider_reference
      t.string :record_type
      t.string :internal_type
      t.bigint :internal_id
      t.bigint :expected_amount
      t.bigint :actual_amount
      t.string :currency
      t.string :status
      t.string :discrepancy_type
      t.jsonb :details

      t.timestamps
    end

    add_index :reconciliation_records,
      [ :provider, :provider_reference ],
      unique: true

    add_index :reconciliation_records,
      [ :internal_type, :internal_id ]

    add_index :reconciliation_records, :status

    add_index :reconciliation_records, :discrepancy_type
  end
end
