class CreateWithdrawals < ActiveRecord::Migration[8.1]
  def change
    create_table :withdrawals do |t|
      t.references :user, null: false, foreign_key: true
      t.references :wallet, null: false, foreign_key: true
      t.bigint :amount, null: false
      t.references :currency, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_withdrawal_id
      t.string :status, null: false, default: 'pending'
      t.string :failure_code
      t.text :failure_message

      t.timestamps
    end

    add_index :withdrawals, [ :provider, :provider_withdrawal_id ], unique: true
  end
end
