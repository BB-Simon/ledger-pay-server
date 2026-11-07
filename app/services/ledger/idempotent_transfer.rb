require "digest"
module Ledger
  class IdempotentTransfer
    def self.call(
      from_wallet:,
      to_wallet:,
      amount:,
      user:,
      idempotency_key:
    )
    new(
      from_wallet: from_wallet,
      to_wallet: to_wallet,
      amount: amount,
      user: user,
      idempotency_key: idempotency_key
    ).call
    end

    def initialize(
      from_wallet:,
      to_wallet:,
      amount:,
      user:,
      idempotency_key:
    )
      @from_wallet = from_wallet
      @to_wallet = to_wallet
      @amount = amount
      @user = user
      @idempotency_key = idempotency_key
    end

    # The key, the transfer and the link between them commit together or not
    # at all. A concurrent request with the same key waits on the key row
    # (its INSERT or its lock) until this one commits, then replays the result.
    def call
      request_hash = generate_request_hash

      IdempotencyKey.transaction do
        record = find_or_create_idempotency_key(request_hash)
        record.lock!

        if record.request_hash != request_hash
          raise ArgumentError, "Idempotency key already exists with a different request hash"
        end

        record.ledger_transaction || perform_transfer!(record)
      end
    end

    private

    def perform_transfer!(record)
      transfer = Ledger::Transfer.call(
        from_wallet: @from_wallet,
        to_wallet: @to_wallet,
        amount: @amount,
        reference: SecureRandom.uuid
      )

      record.update!(
        status: "completed",
        ledger_transaction: transfer
      )

      AuditLogs::Record.call(
        action: "transfer.completed",
        auditable: transfer,
        user: @user,
        metadata: {
          amount: @amount,
          currency: @from_wallet.currency.code,
          from_wallet_id: @from_wallet.id,
          to_wallet_id: @to_wallet.id
        }
      )

      transfer
    end

    # Hash stable values only. Joining the Wallet objects themselves would use
    # their memory address, which differs on every request.
    def generate_request_hash
      payload = [
        @from_wallet.id,
        @to_wallet.id,
        @amount
      ].join(":")

      Digest::SHA256.hexdigest(payload)
    end

    # The INSERT runs in a savepoint so a unique-key conflict doesn't abort
    # the surrounding transaction.
    def find_or_create_idempotency_key(request_hash)
      IdempotencyKey.transaction(requires_new: true) do
        IdempotencyKey.create!(
          user: @user,
          key: @idempotency_key,
          request_hash: request_hash,
          status: "processing"
        )
      end
    rescue ActiveRecord::RecordNotUnique
      IdempotencyKey.find_by!(
        user: @user,
        key: @idempotency_key
      )
    end
  end
end
