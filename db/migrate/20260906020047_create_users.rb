class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :status, null: false, default: "active"

      t.timestamps

      t.index :email, unique: true
    end
  end
end
