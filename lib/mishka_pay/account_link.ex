# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.AccountLink do
  @moduledoc """
  A one-time link that sends a seller to the provider's own pages for their connected account
  (`MishkaPay.ConnectedAccount`). A guarded_struct.

  `MishkaPay.account_link/1` makes one from what the caller gives:

    * `:provider`, `:tenant`, `:account_id`: whose account, with the platform's keys.
    * `:api`: which of the provider's APIs makes the link, `:v2` or `:v1` (Stripe's
      `/v2/core/account_links` or `/v1/account_links`); left out, the tenant's `:connect_api`
      setting (`:v2` by default). Either API links an account made with either.
    * `:type`: `:onboarding` (the default: the seller fills in what the provider needs before
      they take money) or `:update` (they change their details later; only where the platform
      collects them, such as a `:custom` account).
    * `:refresh_url`: where the seller lands when the link ran out or was used already; that page
      makes a new link and sends them on.
    * `:return_url`: where they come back when they are done or leave. Coming back does not mean
      the account is ready: read it again (`:details_submitted`, `:charges_enabled`,
      `:requirements_due`).

  Both URLs are `https`, or `http` on `localhost`.

  `MishkaPay.login_link/3` makes the other kind, `type: :login`: a link into the seller's own
  light dashboard at the provider (Stripe's Express dashboard), only for an `:express` account
  that finished onboarding. Stripe makes it only on `/v1/accounts/:id/login_links` (Accounts v2
  has none), which takes an account made with either API.

  What the provider fills in: `:url`, and `:expires_at` for an onboarding or update link (minutes
  at Stripe). Make one per click and never store it.
  """

  use GuardedStruct

  alias MishkaPay.Helpers.Choice

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :pages} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :account_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :api, :v2 | :v1,
      derives: "validate(enum=Atom[v2::v1])",
      validator: {MishkaPay.ConnectedAccount, :api}

    field :type, :onboarding | :update | :login,
      default: :onboarding,
      derives: "validate(not_nil_value, enum=Atom[onboarding::update::login])",
      validator: {__MODULE__, :type}

    field :refresh_url, String.t(),
      derives: "sanitize(trim) validate(string, not_empty)",
      validator: {MishkaPay.Checkout, :return_url}

    field :return_url, String.t(),
      derives: "sanitize(trim) validate(string, not_empty)",
      validator: {MishkaPay.Checkout, :return_url}

    field :url, String.t(), derives: "validate(string)"
    field :expires_at, DateTime.t(), derives: "validate(struct)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc false
  def type(field, value), do: Choice.atom(field, value, ~w(onboarding update login)a)

  # An onboarding or update link needs both pages to send the seller back to; a login link none.
  @doc false
  def pages(attrs) do
    type = attrs |> value(:type) |> to_string()

    case Enum.find([:refresh_url, :return_url], &is_nil(value(attrs, &1))) do
      field when type != "login" and not is_nil(field) ->
        {:error,
         %{
           field: field,
           action: :pages,
           message: MishkaPay.Messages.text(:customer_needs, field: field)
         }}

      _fits ->
        {:ok, attrs}
    end
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
