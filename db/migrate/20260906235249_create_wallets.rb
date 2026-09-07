class CreateWallets < ActiveRecord::Migration[8.1]
  def change
    create_table :wallets do |t|
      t.references :user, null: false, foreign_key: true
      t.references :currency, null: false, foreign_key: true
      t.string :status

      t.timestamps
    end

    add_index :wallets, [ :user_id, :currency_id ], unique: true
  end
end
