defmodule Shop.Pay.Invoice do
  @moduledoc """
  One row per Stripe bill (invoice) the site makes and manages from its admin, kept by Mishka
  Pay's `:invoice` kind.
  """

  use Ash.Resource,
    domain: Shop.Pay,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  mishka_pay do
    kind :invoice
  end

  postgres do
    table "pay_invoices"
    repo Shop.Repo
  end
end
