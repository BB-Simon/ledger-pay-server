class AddResolutionStatusToReconciliationRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :reconciliation_records, :resolution_status, :string, default: 'open', null: false
  end
end
