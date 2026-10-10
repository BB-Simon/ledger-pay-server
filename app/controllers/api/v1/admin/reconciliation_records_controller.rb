module Api
  module V1
    module Admin
      class ReconciliationRecordsController < ApplicationController
        before_action :authenticate_user!

        def index
          records = ReconciliationRecord
            .order(created_at: :desc)

          records = records.where(
            status: params[:status]
          ) if params[:status].present?

          records = records.where(
            record_type: params[:record_type]
          ) if params[:record_type].present?

          render json: records.map { |record|
            reconciliation_json(record)
          }
        end

        def show
          record = ReconciliationRecord.find(params[:id])

          render json: reconciliation_json(record)
        end

        private

        def reconciliation_json(record)
          {
            id: record.id,
            provider: record.provider,
            provider_reference: record.provider_reference,
            record_type: record.record_type,
            internal_type: record.internal_type,
            internal_id: record.internal_id,
            expected_amount: record.expected_amount,
            actual_amount: record.actual_amount,
            currency: record.currency,
            status: record.status,
            discrepancy_type: record.discrepancy_type,
            details: record.details,
            created_at: record.created_at
          }
        end
      end
    end
  end
end
