class AuditLog < ApplicationRecord
  belongs_to :user, optional: true

  validates :action, presence: true
  validates :auditable_type, presence: true
  validates :auditable_id, presence: true

  def readonly?
    persisted?
  end
end
