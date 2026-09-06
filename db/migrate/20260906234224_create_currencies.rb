class CreateCurrencies < ActiveRecord::Migration[8.1]
  def change
    create_table :currencies do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.integer :decimal_places, null: false, default: 2

      t.timestamps
    end

    add_index :currencies, :code, unique: true
  end
end
