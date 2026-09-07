class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.references :wallet, foreign_key: true, index: { unique: true }
      t.references :currency, null: false, foreign_key: true
      t.string :account_type, null: false
      t.string :status, null: false, default: "active"

      t.timestamps
    end
  end
end
