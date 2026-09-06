class AddUsersIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :users, :status
  end
end
