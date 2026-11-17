# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ConnectedAccount do
  @moduledoc """
  A seller's own account under a platform (a connected account, `acct_...` at Stripe Connect):
  each site of a multi-site platform, or each seller of a marketplace, takes its money there.
  Made with `MishkaPay.create_connected_account/1`, read with `MishkaPay.fetch_connected_account/4`
  and `MishkaPay.list_connected_accounts/3`, changed with `MishkaPay.update_connected_account/1`
  and closed with `MishkaPay.close_connected_account/4`. The seller fills in their details on the
  provider's own pages (`MishkaPay.account_link/1`). A guarded_struct.

  Once made, the site's keys name it as their `:account_id` (`MishkaPay.Credentials`), so the
  site's payments run on it.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys (the platform's).
    * `:api`: which of the provider's APIs to use, `:v2` or `:v1` (Stripe's Accounts v2 or v1);
      left out, the tenant's `:connect_api` setting (`:v2` by default). A read answers the API it
      was read with.
    * `:configurations`: what the account does, `:merchant` (takes payments from buyers),
      `:recipient` (takes transfers from the platform) and `:customer` (pays the platform);
      `[:merchant, :recipient]` when an account is made without them. Each asks for what it needs: a merchant card
      payments, a recipient transfers into its balance. Accounts v1 has no `:customer`.
    * `:dashboard`: what the seller sees at the provider: `:express` (when an account is made
      without one: a light dashboard), `:full` (the seller's own full account) or `:none` (nothing; the platform
      collects every detail).
    * `:fees_collector`, `:losses_collector`: who pays the provider's fees and who answers for
      losses, `:application` (the platform) or `:stripe` (the provider, with the seller); left
      out, what the dashboard needs (`:application` for `:express` and `:none`, `:stripe` for
      `:full`).
    * `:country`: the seller's country, two letters (`"US"`, `"DE"`).
    * `:email`, `:business_name`: who the seller is, prefilled on their pages.
    * `:capabilities`: more than the configurations ask for, by the provider's names. At Stripe
      on v2 each is its configuration and its path there (`"merchant.klarna_payments"`,
      `"recipient.stripe_balance.stripe_transfers"`); on v1 its plain name (`"transfers"`).
    * `:reference`: the host's own id for the seller; it makes the idempotency key, so the same
      reference never makes two accounts, and it comes back on every read.
    * `:metadata`: string keys and values kept with it.

  An update sends only what is given: the configurations and capabilities given are added to
  those the account has.

  What the provider fills in: `:id`; `:charges_enabled`, `:payouts_enabled` and
  `:transfers_enabled` once the seller is set up; `:details_submitted`, whether the seller has
  given everything asked of them; `:requirements_due`, what the provider still needs from the
  seller; `:disabled_reason`, why a capability is held back; `:capability_status`, each
  capability's state (`:active`, `:pending`, `:restricted`, `:rejected`, `:unsupported`,
  `:inactive`); `:default_currency`; `:closed`; `:created_at`.

  A list at Stripe on v2 answers each account's own fields only (configurations, dashboard,
  email, name, metadata, closed): read one with `MishkaPay.fetch_connected_account/4` for its
  states and what it still needs.
  """

  use GuardedStruct

  alias MishkaPay.Helpers.Choice

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :api, :v2 | :v1,
      derives: "validate(enum=Atom[v2::v1])",
      validator: {__MODULE__, :api}

    field :configurations, [:merchant | :recipient | :customer],
      derives: "validate(list)",
      validator: {__MODULE__, :configurations}

    field :dashboard, :express | :full | :none,
      derives: "validate(enum=Atom[express::full::none])",
      validator: {__MODULE__, :dashboard}

    field :fees_collector, :application | :stripe,
      derives: "validate(enum=Atom[application::stripe])",
      validator: {__MODULE__, :collector}

    field :losses_collector, :application | :stripe,
      derives: "validate(enum=Atom[application::stripe])",
      validator: {__MODULE__, :collector}

    field :country, String.t(),
      derives: "sanitize(trim, upcase) validate(string, regex=^[A-Z]{2}$)"

    field :email, String.t(), derives: "sanitize(trim, downcase) validate(string, email_r)"

    field :business_name, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=255)"

    field :capabilities, [String.t()], derives: "validate(list)", validator: {__MODULE__, :names}

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}

    field :charges_enabled, boolean(), default: false, derives: "validate(boolean)"
    field :payouts_enabled, boolean(), default: false, derives: "validate(boolean)"
    field :transfers_enabled, boolean(), default: false, derives: "validate(boolean)"
    field :details_submitted, boolean(), default: false, derives: "validate(boolean)"
    field :requirements_due, [String.t()], default: [], derives: "validate(list)"
    field :disabled_reason, String.t(), derives: "validate(string)"
    field :capability_status, map(), default: %{}, derives: "validate(map)"
    field :default_currency, String.t(), derives: "validate(string)"
    field :closed, boolean(), default: false, derives: "validate(boolean)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc false
  def api(field, value), do: Choice.atom(field, value, ~w(v2 v1)a)

  @doc false
  def dashboard(field, value), do: Choice.atom(field, value, ~w(express full none)a)

  @doc false
  def collector(field, value), do: Choice.atom(field, value, ~w(application stripe)a)

  @doc false
  def configurations(field, values),
    do: Choice.atoms(field, values, [:merchant, :recipient, :customer])

  # A capability's name goes into the provider's params: lowercase words of letters, digits and
  # `_`, joined by dots.
  @doc false
  def names(field, nil), do: {:ok, field, nil}

  def names(field, names) when is_list(names) do
    case Enum.all?(
           names,
           &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9_]+(\.[a-z0-9_]+)*\z/, &1))
         ) do
      true -> {:ok, field, names}
      false -> {:error, field, MishkaPay.Messages.text(:capability_names)}
    end
  end

  def names(field, _other), do: {:error, field, MishkaPay.Messages.text(:capability_names)}
end
