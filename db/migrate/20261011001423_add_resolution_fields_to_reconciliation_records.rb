class AddResolutionFieldsToReconciliationRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :reconciliation_records, :resolved_at, :datetime
    add_column :reconciliation_records, :resolved_by_id, :bigint
    add_column :reconciliation_records, :resolution_notes, :text

    add_foreign_key :reconciliation_records,
      :users,
      column: :resolved_by_id

    add_index :reconciliation_records, :resolved_by_id
  end
end
