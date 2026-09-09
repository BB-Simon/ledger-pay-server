class RenameTransactionToLedgerTransactionInIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    rename_column :idempotency_keys, :transaction_id, :ledger_transaction_id
  end
end
