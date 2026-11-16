# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PaymentLink do
  @moduledoc """
  A page that sells catalog prices to anyone who opens it (`https://buy.stripe.com/...` at
  Stripe), made once and put on a website, in an email or a QR code. A guarded_struct. Each buyer
  who opens it gets their own checkout, so its sales come in like any other: `checkout.session`
  and `payment_intent` webhooks, read with `MishkaPay.fetch_payment/3`.

  Made with `MishkaPay.create_payment_link/1`, read with `MishkaPay.fetch_payment_link/3` and
  `MishkaPay.list_payment_links/3`, turned off or on again with `MishkaPay.update_payment_link/1`
  (`active: false`). A link cannot be deleted; a turned-off link refuses buyers.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:items`: catalog prices by id with their quantity (`[%{id: "price_...", quantity: 1}]`); a
      recurring price makes it a subscription link.
    * `:success_url`: where the buyer goes after paying; left out, the provider shows its own
      thank-you page.
    * `:max_purchases`: how many purchases it takes before it turns itself off: `1` for a
      one-time link, any count for a limited one; left out, no limit.
    * `:inactive_message`: what a buyer reads on it once it is off or used up.
    * `:quantity_min`, `:quantity_max`: let the buyer change how many they take, within these.
    * `:allow_promotion_codes`, `:automatic_tax`, `:invoice`, `:trial_days`,
      `:customer_creation`, `:billing_address`, `:tax_id_collection`, `:merchant_of_record`: as
      on a `MishkaPay.Checkout`; the tenant's settings give `:automatic_tax` and
      `:merchant_of_record` when the link does not. A provider that is the merchant of record
      (Stripe Managed Payments) always makes an invoice.
    * `:metadata`: extra pairs, string keys to string values.

  Every option left out is the provider's own default.

  What the provider fills in: `:id`, `:url`, `:active`, `:purchases` (how many so far, with
  `:max_purchases`), `:created_at`.

  `url/2` adds one buyer's details to the link's address: `reference:` (the host's order or user
  id, which comes back as the checkout's `:reference`), `email:`, `locale:` and `promotion_code:`.
  """

  use GuardedStruct

  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :catalog_items} do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :url, String.t(), derives: "validate(string)"
    field :active, boolean(), derives: "validate(boolean)"
    field :items, list(), structs: MishkaPay.Price, derives: "validate(list)"

    field :success_url, String.t(),
      derives: "sanitize(trim) validate(string)",
      validator: {MishkaPay.Checkout, :return_url}

    field :allow_promotion_codes, boolean(), derives: "validate(boolean)"
    field :automatic_tax, boolean(), derives: "validate(boolean)"
    field :invoice, boolean(), derives: "validate(boolean)"
    field :trial_days, pos_integer(), derives: "validate(integer, min_len=1)"
    field :max_purchases, pos_integer(), derives: "validate(integer, min_len=1)"
    field :purchases, non_neg_integer(), derives: "validate(integer)"

    field :inactive_message, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=500)"

    field :quantity_min, pos_integer(), derives: "validate(integer, min_len=1, max_len=999999)"
    field :quantity_max, pos_integer(), derives: "validate(integer, min_len=1, max_len=999999)"

    field :customer_creation, :always | :if_required,
      derives: "validate(enum=Atom[always::if_required])",
      validator: {MishkaPay.Checkout, :customer_creation}

    field :billing_address, :auto | :required,
      derives: "validate(enum=Atom[auto::required])",
      validator: {MishkaPay.Checkout, :billing_address}

    field :tax_id_collection, boolean(), derives: "validate(boolean)"
    field :merchant_of_record, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  # Runs before the items are built, so an item may still be a map from JSON, with string keys.
  @doc false
  def catalog_items(%{items: items} = attrs) when is_list(items) and items != [] do
    case Enum.all?(items, &known_price?/1) do
      true -> quantity_range(attrs)
      false -> {:error, %{field: :items, action: :items, message: Messages.text(:link_items)}}
    end
  end

  def catalog_items(%{items: nil} = attrs), do: {:ok, attrs}

  def catalog_items(%{items: _empty_or_not_a_list}),
    do: {:error, %{field: :items, action: :items, message: Messages.text(:link_items)}}

  def catalog_items(attrs), do: quantity_range(attrs)

  defp quantity_range(%{quantity_min: min, quantity_max: max})
       when is_integer(min) and is_integer(max) and min >= max,
       do:
         {:error,
          %{field: :quantity_min, action: :quantity, message: Messages.text(:quantity_range)}}

  defp quantity_range(attrs), do: {:ok, attrs}

  defp known_price?(%{id: id}) when is_binary(id), do: true
  defp known_price?(%{"id" => id}) when is_binary(id), do: true
  defp known_price?(_not_from_the_catalog), do: false

  @url_params %{
    reference: "client_reference_id",
    email: "prefilled_email",
    locale: "locale",
    promotion_code: "prefilled_promo_code"
  }

  @doc """
  The link's address for one buyer: `reference:` (letters, digits, `_` and `-`, at most 200),
  `email:`, `locale:` and `promotion_code:` are filled in on the provider's page. Raises
  `ArgumentError` for a reference the provider would drop.

      MishkaPay.PaymentLink.url(link, reference: "order-42", email: "ava@example.com")
      #=> "https://buy.stripe.com/test_...?client_reference_id=order-42&prefilled_email=..."
  """
  @spec url(t(), keyword()) :: String.t()
  def url(%__MODULE__{url: url}, opts \\ []) when is_binary(url) do
    reference(opts[:reference])

    query =
      for {key, name} <- @url_params, value = opts[key], not is_nil(value), do: {name, value}

    case query do
      [] -> url
      _some -> url <> "?" <> URI.encode_query(query)
    end
  end

  defp reference(nil), do: :ok

  defp reference(reference) do
    case is_binary(reference) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,200}\z/, reference) do
      true -> :ok
      false -> raise ArgumentError, Messages.text(:link_reference)
    end
  end
end
