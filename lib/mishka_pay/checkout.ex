# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Checkout do
  @moduledoc """
  A checkout: what the buyer pays for and where they come back to, then the provider's answer. A
  guarded_struct; `MishkaPay.checkout/1` builds it from a map and hands it to the provider.

  Read back with `MishkaPay.fetch_checkout/3`, `:items` are what the buyer bought, with their
  provider price and product ids.

  What the caller gives:

    * `:provider` and `:tenant`: which provider, with whose keys (`MishkaPay.Credentials`).
    * `:items`: one or more `MishkaPay.Price`, all in one currency.
    * `:success_url`, `:cancel_url`: where the buyer is sent after paying or giving up; `https`, or
      `http` on `localhost`.
    * `:customer`: an optional buyer: `%{id: "cus_..."}` for a customer the provider keeps, or
      `%{email: "..."}` to fill in a new buyer's email; one or the other (`MishkaPay.Customer`).
    * `:reference`: the caller's own id for this sale, such as an order id. The provider keeps it,
      it comes back on the payment, and it makes the request's idempotency key, so the same
      reference never opens two checkouts.
    * `:owner`: who the sale is for in the caller's app, such as the signed-in user's id. The
      provider keeps it on the payment or the subscription, and it comes back on either
      (`MishkaPay.Payment`, `MishkaPay.Subscription`), so access can be given to that user. The
      Ash layer fills it from the actor (`MishkaPay.Ash.Resource`).
    * `:merchant_of_record`: `true` asks the provider to sell as the merchant of record (it
      collects and files the tax, as Stripe Managed Payments does), `false` asks it not to; left
      out, the provider's account default applies. Each price then needs its `:tax_code`.
    * `:metadata`: extra pairs kept with the checkout, string keys to string values; each provider
      has its own limits on how many and how long.
    * `:mode`: `:payment` (the default) sells once; `:subscription` starts a subscription, so
      every item needs a recurring price (`:interval`, or a provider price `:id`) and the provider
      needs `:subscription`. A one-time checkout refuses a recurring price.
    * `:trial_days`: with `:subscription`, how many days the buyer uses it before the first
      charge.
    * `:discounts`: coupons or promotion codes the checkout applies by itself
      (`MishkaPay.Discount`), or `:allow_promotion_codes`: `true` lets the buyer type a code. One
      or the other.
    * `:automatic_tax`: `true` has the provider count the tax from the buyer's address (Stripe
      Tax); each price then needs its `:tax_code`.
    * `:customer_creation`: in a one-time checkout, `:always` makes a provider customer for the
      buyer, `:if_required` only when the provider needs one.
    * `:locale`: the language of the provider's page (`"de"`, `"auto"`).
    * `:expires_at`: when the checkout stops taking payment; the provider has its own limits
      (Stripe: 30 minutes to 24 hours from now). `MishkaPay.expire_checkout/3` ends it at once.
    * `:billing_address`: `:auto` (only when needed) or `:required`.
    * `:tax_id_collection`: `true` lets a business buyer give its tax id.
    * `:invoice`: in a one-time checkout, `true` makes an invoice for the payment, which the
      provider can email with the receipt; a subscription makes its own invoices.

  A provider refuses an option it cannot honour (`MishkaPay.Errors.Unsupported`) rather than
  leaving it out. Which payment methods a Stripe checkout offers is set in the Stripe Dashboard.

  What the provider fills in:

    * `:id`: the provider's id of the checkout (`cs_...` at Stripe).
    * `:url`: the page to send the buyer to.
    * `:status`: `:open`, `:complete` or `:expired`.
    * `:payment_id`: the payment it made, once there is one (a one-time checkout).
    * `:subscription_id`: the subscription it started, once there is one.
    * `:invoice_id`: the invoice it made, with `invoice: true`, once paid.
    * `:payment_link_id`: the payment link the buyer came from (`MishkaPay.PaymentLink`).
    * `:amount_total`, `:amount_tax`, `:amount_discount`: what the buyer pays in all, the tax in
      it and the discount taken off, as `Money`, once the provider has counted them (the tax may
      change as the buyer fills in an address).
  """

  use GuardedStruct

  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :consistent} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :items, list(),
      enforce: true,
      structs: MishkaPay.Price,
      derives: "validate(not_nil_value, list)"

    field :success_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string)",
      validator: {__MODULE__, :return_url}

    field :cancel_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string)",
      validator: {__MODULE__, :return_url}

    field :customer, struct(), struct: MishkaPay.Customer

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :owner, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    field :merchant_of_record, boolean(), derives: "validate(boolean)"

    dynamic_field :metadata, validator: {__MODULE__, :metadata}

    field :id, String.t(), derives: "validate(string)"
    field :url, String.t(), derives: "validate(string)"

    field :status, :open | :complete | :expired,
      derives: "validate(enum=Atom[open::complete::expired])"

    field :mode, :payment | :subscription,
      default: :payment,
      derives: "validate(not_nil_value, enum=Atom[payment::subscription])",
      validator: {__MODULE__, :mode}

    field :trial_days, pos_integer(), derives: "validate(integer, min_len=1)"

    field :discounts, list(),
      structs: MishkaPay.Discount,
      derives: "validate(list)"

    field :allow_promotion_codes, boolean(), derives: "validate(boolean)"
    field :automatic_tax, boolean(), derives: "validate(boolean)"

    field :customer_creation, :always | :if_required,
      derives: "validate(enum=Atom[always::if_required])",
      validator: {__MODULE__, :customer_creation}

    field :locale, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=10)"
    field :expires_at, DateTime.t(), derives: "validate(struct)", validator: {__MODULE__, :later}

    field :billing_address, :auto | :required,
      derives: "validate(enum=Atom[auto::required])",
      validator: {__MODULE__, :billing_address}

    field :tax_id_collection, boolean(), derives: "validate(boolean)"
    field :invoice, boolean(), derives: "validate(boolean)"
    field :invoice_id, String.t(), derives: "validate(string)"
    field :payment_link_id, String.t(), derives: "validate(string)"

    field :payment_id, String.t(), derives: "validate(string)"
    field :subscription_id, String.t(), derives: "validate(string)"
    field :amount_total, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_tax, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_discount, Money.t(), validator: {MishkaPay.Money, :field}
  end

  # Choices from JSON or a form come as strings.
  @doc false
  def customer_creation(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(always if_required))

  @doc false
  def billing_address(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(auto required))

  # A checkout that expires is one that has not expired yet.
  @doc false
  def later(field, %DateTime{} = at) do
    case DateTime.compare(at, DateTime.utc_now()) do
      :gt -> {:ok, field, at}
      _past -> {:error, field, Messages.text(:expires_past)}
    end
  end

  def later(field, at), do: {:ok, field, at}

  @doc false
  def return_url(field, url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host} when host not in [nil, ""] -> {:ok, field, url}
      %URI{scheme: "http", host: "localhost"} -> {:ok, field, url}
      _other -> {:error, field, Messages.text(:return_url, field: field)}
    end
  end

  def return_url(field, url), do: {:ok, field, url}

  @doc false
  def metadata(field, nil), do: {:ok, field, nil}

  def metadata(field, %{} = metadata) do
    case Enum.all?(metadata, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      true -> {:ok, field, metadata}
      false -> {:error, field, Messages.text(:metadata_strings)}
    end
  end

  def metadata(field, _other),
    do: {:error, field, Messages.text(:metadata_strings)}

  # A mode from JSON or a form comes as a string.
  @doc false
  def mode(:mode, mode) when mode in ["payment", "subscription"],
    do: {:ok, :mode, String.to_existing_atom(mode)}

  def mode(:mode, mode), do: {:ok, :mode, mode}

  # One currency across the items, and items that fit the mode: recurring prices for a
  # subscription, one-time prices for a payment. Runs before the items are built, so an item may
  # still be a map from JSON, with string keys. An items list that failed to build is already
  # reported on its own.
  @doc false
  def consistent(attrs) do
    with {:ok, attrs} <- one_currency(attrs),
         {:ok, attrs} <- one_buyer(attrs),
         {:ok, attrs} <- one_discount_way(attrs),
         {:ok, attrs} <- customer_creation_mode(attrs),
         {:ok, attrs} <- invoice_mode(attrs),
         do: fits_mode(attrs)
  end

  # Discounts the checkout applies, or codes the buyer types: providers take one or the other.
  defp one_discount_way(attrs) do
    case {key(attrs, :discounts), key(attrs, :allow_promotion_codes)} do
      {[_ | _], true} ->
        {:error,
         %{field: :discounts, action: :discounts, message: Messages.text(:discounts_or_codes)}}

      _one_way ->
        {:ok, attrs}
    end
  end

  # A subscription bills itself with invoices; asking for one is a one-time checkout's choice.
  defp invoice_mode(attrs) do
    case {key(attrs, :invoice), key(attrs, :mode)} do
      {true, mode} when mode in [:subscription, "subscription"] ->
        {:error, %{field: :invoice, action: :mode, message: Messages.text(:invoice_mode)}}

      _fits ->
        {:ok, attrs}
    end
  end

  # A subscription always has a customer; making one is a choice of a one-time checkout only.
  defp customer_creation_mode(attrs) do
    case {key(attrs, :customer_creation), key(attrs, :mode)} do
      {creation, mode} when not is_nil(creation) and mode in [:subscription, "subscription"] ->
        {:error,
         %{
           field: :customer_creation,
           action: :mode,
           message: Messages.text(:customer_creation_mode)
         }}

      _fits ->
        {:ok, attrs}
    end
  end

  # A checkout names its buyer by the provider's id or by an email, not both.
  defp one_buyer(%{customer: %{} = customer} = attrs) do
    case {is_binary(key(customer, :id)), is_binary(key(customer, :email))} do
      {true, true} ->
        {:error, %{field: :customer, action: :customer, message: Messages.text(:customer_one_of)}}

      {false, false} ->
        {:error, %{field: :customer, action: :customer, message: Messages.text(:customer_one_of)}}

      _one ->
        {:ok, attrs}
    end
  end

  defp one_buyer(attrs), do: {:ok, attrs}

  defp fits_mode(%{mode: mode, items: items} = attrs)
       when mode in [:subscription, "subscription"] and is_list(items) do
    case Enum.all?(items, &(recurring?(&1) or known?(&1))) do
      true -> {:ok, attrs}
      false -> {:error, %{field: :items, action: :mode, message: Messages.text(:items_recurring)}}
    end
  end

  defp fits_mode(%{trial_days: days}) when is_integer(days),
    do: {:error, %{field: :trial_days, action: :mode, message: Messages.text(:trial_mode)}}

  defp fits_mode(%{items: items} = attrs) when is_list(items) do
    case Enum.any?(items, &recurring?/1) do
      false -> {:ok, attrs}
      true -> {:error, %{field: :items, action: :mode, message: Messages.text(:items_one_time)}}
    end
  end

  defp fits_mode(attrs), do: {:ok, attrs}

  defp recurring?(item), do: not is_nil(key(item, :interval))
  defp known?(item), do: is_binary(key(item, :id))

  defp key(%{} = item, name), do: Map.get(item, name) || Map.get(item, Atom.to_string(name))
  defp key(_not_a_map, _name), do: nil

  defp one_currency(%{items: []}),
    do: {:error, %{field: :items, action: :items, message: Messages.text(:items_empty)}}

  defp one_currency(%{items: items} = attrs) when is_list(items) do
    case items |> MapSet.new(&currency/1) |> MapSet.delete(nil) |> MapSet.size() do
      count when count <= 1 ->
        {:ok, attrs}

      _many ->
        {:error, %{field: :items, action: :currency, message: Messages.text(:items_currency)}}
    end
  end

  defp one_currency(attrs), do: {:ok, attrs}

  # The item's money read the way MishkaPay.Money reads it; an item it refuses is reported by the
  # item itself.
  defp currency(%{amount: amount}) do
    case MishkaPay.Money.field(:amount, amount) do
      {:ok, :amount, %Money{currency: currency}} -> currency
      _no_money -> nil
    end
  end

  defp currency(_known_price), do: nil
end
