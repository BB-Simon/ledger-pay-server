class CreateRefunds < ActiveRecord::Migration[8.1]
  def change
    create_table :refunds do |t|
      t.references :payment, null: false, foreign_key: true
      t.bigint :amount, null: false
      t.string :provider, null: false
      t.string :provider_refund_id
      t.string :status, null: false, default: 'pending'
      t.string :reason

      t.timestamps
    end

    add_index :refunds, [ :provider, :provider_refund_id ], unique: true
  end
end
