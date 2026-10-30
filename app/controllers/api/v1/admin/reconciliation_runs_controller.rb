
module Api
  module V1
    module Admin
      class ReconciliationRunsController < ApplicationController
        before_action :authenticate_user!
        before_action :require_admin!
        before_action :set_run, only: :show
        before_action :set_item, only: :retry_item

        def index
          runs = ReconciliationRun.order(created_at: :desc).limit(100)

          render json: runs.map { |run| serialize_run(run) }
        end

        def show
          render json: {
            run: serialize_run(@run),
            items: @run.reconciliation_run_items
              .order(:id)
              .map { |item| serialize_item(item) }
          }
        end

        def retry_item
          Reconciliation::RetryRunItem.call(
            item: @item,
            user: current_user,
            ip_address: request.remote_ip,
            request_id: request.request_id
          )

          render json: {
            message: "Retry enqueued",
            item: serialize_item(@item.reload)
          }, status: :accepted
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_run
          @run = ReconciliationRun.find(params[:id])
        end

        def set_item
          @item = ReconciliationRunItem.find_by!(
            id: params[:id],
            reconciliation_run_id: params[:run_id]
          )
        end

        def serialize_run(run)
          {
            id: run.id,
            provider: run.provider,
            run_type: run.run_type,
            status: run.status,
            total_items: run.total_items,
            records_checked: run.records_checked,
            matched_count: run.matched_count,
            discrepancy_count: run.discrepancy_count,
            failed_count: run.failed_count,
            started_at: run.started_at,
            completed_at: run.completed_at,
            error_message: run.error_message
          }
        end

        def serialize_item(item)
          {
            id: item.id,
            record_type: item.record_type,
            internal_type: item.internal_type,
            internal_id: item.internal_id,
            provider_reference: item.provider_reference,
            status: item.status,
            attempts: item.attempts,
            started_at: item.started_at,
            completed_at: item.completed_at,
            error_class: item.error_class,
            error_message: item.error_message
          }
        end
      end
    end
  end
end
