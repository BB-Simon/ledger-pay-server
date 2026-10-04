module AuditLogs
  class Record
    def self.call(
      action:,
      auditable:,
      user: nil,
      metadata: {},
      ip_address: nil,
      request_id: nil
    )
      new(
        action: action,
        auditable: auditable,
        user: user,
        metadata: metadata,
        ip_address: ip_address,
        request_id: request_id
      ).call
    end

    def initialize(
      action:,
      auditable:,
      user:,
      metadata:,
      ip_address:,
      request_id:
    )
      @action = action
      @auditable = auditable
      @user = user
      @metadata = metadata
      @ip_address = ip_address
      @request_id = request_id
    end

    def call
      AuditLog.create!(
        action: @action,
        auditable_type: @auditable.class.name,
        auditable_id: @auditable.id,
        user: @user,
        metadata: @metadata,
        ip_address: @ip_address,
        request_id: @request_id
      )
    end
  end
end
