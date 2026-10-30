class MakeReconciliationRecordOptionalOnResults < ActiveRecord::Migration[8.1]
  def change
    change_column_null :reconciliation_results,
      :reconciliation_record_id, true
  end
end
