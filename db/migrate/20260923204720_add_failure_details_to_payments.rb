class AddFailureDetailsToPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :payments, :failure_code, :string
    add_column :payments, :failure_message, :text
  end
end
