module IdempotencyKeys
  # Finds or creates the caller's idempotency key and locks it. Call it inside
  # the database transaction that creates the record, then link the record
  # with `key.update!(resource: record, status: "completed")`, so the key and
  # the record are committed together.
  #
  # If key.resource is already set, the request was done before: return that
  # record instead of creating another one.
  class Claim
    def self.call(user:, key:, request_hash:)
      record = begin
        # Savepoint, so a duplicate insert doesn't abort the outer transaction.
        IdempotencyKey.transaction(requires_new: true) do
          IdempotencyKey.create!(user: user, key: key, request_hash: request_hash, status: "processing")
        end
      rescue ActiveRecord::RecordNotUnique
        IdempotencyKey.find_by!(user: user, key: key)
      end

      record.lock!

      raise ArgumentError, "Idempotency key was already used for a different request" unless
        record.request_hash == request_hash

      record
    end

    def self.request_hash(*parts)
      Digest::SHA256.hexdigest(parts.join(":"))
    end
  end
end
