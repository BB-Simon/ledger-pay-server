require "swagger_helper"

RSpec.describe "Admin: reconciliation runs", type: :request do
  let(:Authorization) { bearer_for(users(:admin)) }
  let(:run) do
    ReconciliationRun.create!(provider: "stripe", run_type: "payments", status: :failed,
      total_items: 1, failed_count: 1, started_at: 1.hour.ago, completed_at: 50.minutes.ago)
  end
  let(:failed_item) do
    run.reconciliation_run_items.create!(
      record_type: "payment", internal_type: "Payment", internal_id: 1, provider_reference: "pi_doc",
      status: :failed, attempts: 5, error_class: "Stripe::APIConnectionError", error_message: "timeout"
    )
  end

  path "/api/v1/admin/reconciliation_runs" do
    get "List reconciliation runs" do
      tags "Admin: Reconciliation"
      description "Newest first, at most 100."
      produces "application/json"

      response "200", "runs" do
        schema type: :array, items: { "$ref" => "#/components/schemas/ReconciliationRun" }
        before { run }

        run_test!
      end

      response "403", "not an admin" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { bearer_for(users(:alice)) }

        run_test!
      end
    end
  end

  path "/api/v1/admin/reconciliation_runs/{id}" do
    parameter name: :id, in: :path, schema: { type: :integer }

    get "Get a run with its items" do
      tags "Admin: Reconciliation"
      produces "application/json"

      response "200", "the run and its items" do
        schema type: :object, additionalProperties: false,
          properties: {
            run: { "$ref" => "#/components/schemas/ReconciliationRun" },
            items: { type: :array, items: { "$ref" => "#/components/schemas/ReconciliationRunItem" } }
          },
          required: %w[run items]
        let(:id) { failed_item.reconciliation_run_id }

        run_test!
      end
    end
  end

  path "/api/v1/admin/reconciliation_runs/{id}/items/{item_id}/retry" do
    parameter name: :id, in: :path, schema: { type: :integer }, description: "Run id"
    parameter name: :item_id, in: :path, schema: { type: :integer }

    post "Retry a failed run item" do
      tags "Admin: Reconciliation"
      description "Puts a failed item back to pending, reopens the run and enqueues the item's job."
      produces "application/json"
      let(:id) { run.id }
      let(:item_id) { failed_item.id }

      response "202", "retry enqueued" do
        schema type: :object, additionalProperties: false,
          properties: {
            message: { type: :string },
            item: { "$ref" => "#/components/schemas/ReconciliationRunItem" }
          },
          required: %w[message item]

        run_test!
      end

      response "404", "the item doesn't exist in this run" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:id) { ReconciliationRun.create!(provider: "stripe", run_type: "payments", status: :completed).id }

        run_test!
      end

      response "422", "the item isn't failed, or the run is still running" do
        schema "$ref" => "#/components/schemas/Error"
        before { failed_item.update!(status: :matched) }

        run_test!
      end
    end
  end
end
