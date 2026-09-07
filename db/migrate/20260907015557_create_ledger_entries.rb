class CreateLedgerEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :ledger_entries do |t|
      t.references :transaction, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.string :entry_type, null: false
      t.bigint :amount, null: false

      t.timestamps
    end

    add_index :ledger_entries, :entry_type
  end
end
