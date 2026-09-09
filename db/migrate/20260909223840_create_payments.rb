class CreatePayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments do |t|
      t.references :user, null: false, foreign_key: true
      t.references :wallet, null: false, foreign_key: true
      t.bigint :amount, null: false
      t.references :currency, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_payment_id
      t.string :status, null: false, default: 'pending'

      t.timestamps
    end

    add_index :payments, [ :provider, :provider_payment_id ], unique: true
  end
end
