require "digest"

module Ledger
  class IdempotentTransfer
    def call(
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
    )
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

    def call
      request_hash = generate_request_hash

      record = find_or_create_idempotency_key(request_hash)

      if record.transaction
        record.transaction
      end

      transfer = Ledger::Transfer.call(
        from_wallet: @from_wallet,
        to_wallet: @to_wallet,
        amount: @amount,
        reference: SecureRandom.uuid
      )

      redord.update!(
        status: "completed",
        transaction: transfer
      )

      transfer
    end

    private

    def generate_request_hash
      payload = [
        @from_wallet,
        @to_wallet,
        @amount
      ].join(":")

      Digest::SHA256.hexdigest(payload)
    end

    def find_or_create_idempotency_key(request_hash)
      IdempotencyKey.create!(
        user: @user,
        key: @idempotency_key,
        request_hash: request_hash,
        status: "processing"
      )

    rescue ActiveRecord::RecordNotUnique
      record = IdempotencyKey.find_by!(
        user: @user,
        key: @idempotency_key
      )

      if record.request_hash != request_hash
        raise ArgumentError, "Idempotency key already exists with a different request hash"
      end

      record
    end
  end
end
