class RenameTransactionIdToLedgerTransactionId < ActiveRecord::Migration[8.1]
  def change
    rename_column :ledger_entries, :transaction_id, :ledger_transaction_id
  end
end
