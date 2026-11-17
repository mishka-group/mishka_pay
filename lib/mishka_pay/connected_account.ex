# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ConnectedAccount do
  @moduledoc """
  A seller's own account under a platform (a connected account, `acct_...` at Stripe Connect):
  each site of a multi-site platform, or each seller of a marketplace, takes its money there.
  Made with `MishkaPay.create_connected_account/1`, read with `MishkaPay.fetch_connected_account/3`
  and `MishkaPay.list_connected_accounts/3`, changed with `MishkaPay.update_connected_account/1`
  and turned down with `MishkaPay.reject_connected_account/4`. The seller fills in their details
  on the provider's own pages (`MishkaPay.account_link/1`). A guarded_struct.

  Once made, the site's keys name it as their `:account_id` (`MishkaPay.Credentials`), so the
  site's payments run on it.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys (the platform's).
    * `:type`: how much the seller sees and who answers for losses: `:express` (the default: a
      light dashboard of the provider's; the platform pays the fees and answers for losses),
      `:standard` (the seller's own full account and dashboard) or `:custom` (no dashboard: the
      platform collects everything and answers for losses).
    * `:country`: the seller's country, two letters (`"US"`, `"DE"`).
    * `:email`, `:business_name`: who the seller is, prefilled on their pages.
    * `:capabilities`: what the account asks for, by the provider's names
      (`["card_payments", "transfers"]`).
    * `:reference`: the host's own id for the seller; it makes the idempotency key, so the same
      reference never makes two accounts, and it comes back on every read.
    * `:metadata`: string keys and values kept with it.

  What the provider fills in: `:id`; `:charges_enabled` and `:payouts_enabled` once the seller is
  set up; `:details_submitted`; `:requirements_due`, what the provider still needs from the
  seller; `:disabled_reason`; `:capability_status`, each capability's state (`:active`,
  `:inactive`, `:pending`); `:default_currency`; `:created_at`.
  """

  use GuardedStruct

  alias MishkaPay.Helpers.Choice

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :type, :express | :standard | :custom,
      default: :express,
      derives: "validate(not_nil_value, enum=Atom[express::standard::custom])",
      validator: {__MODULE__, :type}

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
    field :details_submitted, boolean(), default: false, derives: "validate(boolean)"
    field :requirements_due, [String.t()], default: [], derives: "validate(list)"
    field :disabled_reason, String.t(), derives: "validate(string)"
    field :capability_status, map(), default: %{}, derives: "validate(map)"
    field :default_currency, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc false
  def type(field, value), do: Choice.atom(field, value, ~w(express standard custom))

  # A capability's name goes into the provider's form keys: lowercase letters, digits and `_`.
  @doc false
  def names(field, nil), do: {:ok, field, nil}

  def names(field, names) when is_list(names) do
    case Enum.all?(names, &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9_]+\z/, &1))) do
      true -> {:ok, field, names}
      false -> {:error, field, MishkaPay.Messages.text(:capability_names)}
    end
  end

  def names(field, _other), do: {:error, field, MishkaPay.Messages.text(:capability_names)}
end
