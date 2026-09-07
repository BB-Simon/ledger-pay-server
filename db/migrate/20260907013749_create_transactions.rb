class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      t.string :reference, null: false
      t.string :transaction_type, null: false
      t.string :status, null: false, default: "posted"
      t.references :currency, null: false, foreign_key: true

      t.timestamps
    end

    add_index :transactions, :reference, unique: true
  end
end
