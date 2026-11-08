require "swagger_helper"

RSpec.describe "Admin: reconciliation records", type: :request do
  let(:Authorization) { bearer_for(users(:admin)) }

  def record(status: :discrepancy, discrepancy_type: :amount_mismatch)
    Reconciliation::CreateRecord.call(
      provider: "stripe", provider_reference: "po_doc", record_type: "payout",
      expected_amount: 400, actual_amount: 500, currency: "usd",
      status: status, discrepancy_type: discrepancy_type, details: { provider_status: "paid" }
    )
  end

  path "/api/v1/admin/reconciliation_records" do
    get "List reconciliation records" do
      tags "Admin: Reconciliation"
      description "Newest first, at most 100."
      produces "application/json"
      parameter name: :status, in: :query, required: false, schema: { type: :string, enum: %w[matched discrepancy] }
      parameter name: :record_type, in: :query, required: false, schema: { type: :string, enum: %w[payment refund payout] }

      response "200", "records" do
        schema type: :array, items: { "$ref" => "#/components/schemas/ReconciliationRecord" }
        let(:status) { "discrepancy" }
        let(:record_type) { "payout" }
        before { record }

        run_test!
      end

      response "401", "not logged in" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { nil }

        run_test!
      end

      response "403", "not an admin" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { bearer_for(users(:alice)) }

        run_test!
      end
    end
  end

  path "/api/v1/admin/reconciliation_records/{id}" do
    parameter name: :id, in: :path, schema: { type: :integer }

    get "Get a reconciliation record" do
      tags "Admin: Reconciliation"
      produces "application/json"

      response "200", "the record" do
        schema "$ref" => "#/components/schemas/ReconciliationRecord"
        let(:id) { record.id }

        run_test!
      end

      response "404", "not found" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:id) { 0 }

        run_test!
      end
    end
  end

  path "/api/v1/admin/reconciliation_records/{id}/resolve" do
    parameter name: :id, in: :path, schema: { type: :integer }

    post "Resolve a discrepancy" do
      tags "Admin: Reconciliation"
      description "Marks an open discrepancy resolved, with notes. It's reopened automatically if a different " \
                  "discrepancy is found later."
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { resolution_notes: { type: :string, example: "Checked with Stripe; fee adjustment." } },
        required: %w[resolution_notes]
      }
      let(:body) { { resolution_notes: "Checked with Stripe" } }

      response "200", "resolved" do
        schema "$ref" => "#/components/schemas/ReconciliationRecord"
        let(:id) { record.id }

        run_test!
      end

      response "422", "not a discrepancy, already resolved, or notes missing" do
        schema "$ref" => "#/components/schemas/Error"
        let(:id) { record(status: :matched, discrepancy_type: nil).id }

        run_test!
      end
    end
  end
end
