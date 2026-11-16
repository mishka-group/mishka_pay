defmodule Shop.Pay.ClockRun do
  @moduledoc """
  One situation the test clocks panel set up: a Stripe test clock, the customer and subscription
  living on its time, and which situation it plays (a renewal that is paid or fails, a trial that
  ends paid or failing).
  """

  use Ash.Resource, domain: Shop.Pay, data_layer: AshPostgres.DataLayer

  postgres do
    table "clock_runs"
    repo Shop.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :start do
      accept [:clock_id, :scenario, :subscription_id, :buyer]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :clock_id, :string, allow_nil?: false, public?: true

    attribute :scenario, :atom,
      constraints: [one_of: [:renews, :renewal_fails, :trial_then_paid, :trial_then_fails]],
      allow_nil?: false,
      public?: true

    attribute :subscription_id, :string, allow_nil?: false, public?: true
    attribute :buyer, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  identities do
    identity :clock, [:clock_id]
  end
end
