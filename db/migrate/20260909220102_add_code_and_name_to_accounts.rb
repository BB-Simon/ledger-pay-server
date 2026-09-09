class AddCodeAndNameToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :name, :string
    add_column :accounts, :code, :string

    add_index :accounts, :code, unique: true
  end
end
