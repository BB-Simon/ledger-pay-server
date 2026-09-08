module Ledger
  class PostTransaction
    def self.call(
      reference:,
      transaction_type:,
      currency:,
      entries:
      )
      new(
        reference: reference,
        transaction_type: transaction_type,
        currency: currency,
        entries: entries
      ).call
    end

    def initialize(
      reference:,
      transaction_type:,
      currency:,
      entries:
    )
      @reference = reference
      @transaction_type = transaction_type
      @currency = currency
      @entries = entries
    end

    def call
      validate!

      Transaction.transaction do
        transaction = Transaction.create!(
          reference: @reference,
          transaction_type: @transaction_type,
          currency: @currency,
          status: :posted
        )

        @entries.each do |entry|
          transaction.ledger_entries.create!(
            account: entry[:account],
            entry_type: entry[:entry_type],
            amount: entry[:amount]
          )
        end
        transaction
      end
    end

    private

    def validate!
      raise ArgumentError, "At least two entries are required" if @entries.size < 2

      validate_amounts!
      validate_entry_types!
      validate_acounts!
      validate_currencies!
      validate_balanced!
    end

    def validate_amounts!
      invalid = @entries.any? do |entry|
        !entry[:amount].is_a?(Integer) || entry[:amount] <= 0
      end

      raise ArgumentError, "Amount must be a positive integer" if invalid
    end

    def validate_entry_types!
      valid_entry_types = %w[debit credit]
      invalid = @entries.any? do |entry|
        !valid_entry_types.include?(entry[:entry_type].to_s)
      end

      raise ArgumentError, "Invalid entry type. Must be either 'debit' or 'credit'" if invalid
    end

    def validate_acounts!
      invalid = @entries.any? do |entry|
        entry[:account].nil? ||
          entry[:account].status != "active"
      end

      raise ArgumentError, "All accounts must be active" if invalid
    end

    def validate_currencies!
      invalid = @entries.any? do |entry|
        entry[:account].currency_id != @currency.id
      end

      raise ArgumentError, "Account currency must match transaction currency" if invalid
    end

    def validate_balanced!
      debits = @entries
        .select { |entry| entry[:entry_type].to_s == "debit" }
        .sum { |entry| entry[:amount] }

      credits = @entries
        .select { |entry| entry[:entry_type].to_s == "credit" }
        .sum { |entry| entry[:amount] }

      return if debits == credits

      raise ArgumentError, "Transaction is not balanced. Total debits (#{debits}) do not equal total credits (#{credits})"
    end
  end
end
