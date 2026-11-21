# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Checkout do
  @moduledoc """
  A checkout: what the buyer pays for and where they come back to, then the provider's answer. A
  guarded_struct; `MishkaPay.checkout/1` builds it from a map and hands it to the provider.

  Read back with `MishkaPay.fetch_checkout/3`, `:items` are what the buyer bought, with their
  provider price and product ids; `:phone_number`, `:field_values` (each field's key to the
  buyer's answer) and `:terms_accepted` are what the buyer gave.

  What the caller gives:

    * `:provider` and `:tenant`: which provider, with whose keys (`MishkaPay.Credentials`).
    * `:items`: one or more `MishkaPay.Price`, all in one currency; none in `mode: :setup`.
    * `:ui_mode`: `:hosted` (the default) sends the buyer to the provider's page; `:embedded`
      shows the provider's form inside the site's own page, and needs `:embedded_checkout`.
    * `:success_url`, `:cancel_url`: with `:hosted`, where the buyer is sent after paying or
      giving up; `https`, or `http` on `localhost`. Both are required.
    * `:return_url`: with `:embedded`, the one address the buyer comes back to after paying, or
      after a payment method's own page. It is required, and replaces the two above. At Stripe,
      `{CHECKOUT_SESSION_ID}` in it becomes the checkout's id.
    * `:customer`: an optional buyer: `%{id: "cus_..."}` for a customer the provider keeps, or
      `%{email: "..."}` to fill in a new buyer's email; one or the other (`MishkaPay.Customer`).
    * `:reference`: the caller's own id for this sale, such as an order id. The provider keeps it,
      it comes back on the payment, and with the request's details it makes the idempotency key,
      so the same request sent twice never opens two checkouts, and the same reference asked again
      with other details is a new request.
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
      needs `:subscription`. A one-time checkout refuses a recurring price. `:setup` saves a
      payment method without charging (below).
    * `:trial_days`: with `:subscription`, how many days the buyer uses it before the first
      charge.
    * `:discounts`: coupons or promotion codes the checkout applies by itself
      (`MishkaPay.Checkout.Discounts`), or `:allow_promotion_codes`: `true` lets the buyer type a
      code. One or the other.
    * `:automatic_tax`: `true` has the provider count the tax from the buyer's address (Stripe
      Tax); each price then needs its `:tax_code`.
    * `:customer_creation`: in a one-time or setup checkout, `:always` makes a provider customer
      for the buyer, `:if_required` only when the provider needs one.
    * `:locale`: the language of the provider's page (`"de"`, `"auto"`).
    * `:terms`: `true` makes the buyer accept the site's terms of service before paying (the
      terms page is set in the provider's account). It helps when a buyer later disputes a sale.
    * `:phone`: `true` asks the buyer for a phone number.
    * `:fields`: up to three questions the page asks, each a `MishkaPay.Checkout.Fields`; the
      answers come back in `:field_values`.
    * `:card_required`: with `:subscription` and a trial, `false` starts the trial without a card;
      the provider asks for one before the first charge.
    * `:billing_mode`: with `:subscription`, how the provider counts prorations and bills:
      `:flexible` (the default, Stripe's recommended mode) or `:classic` (its older counting). Left
      out, the tenant's `:billing_mode` (`MishkaPay.Credentials`) applies, else `:flexible`. It is
      set once, when the subscription is made.
    * `:proration_discounts`: with the flexible billing mode, how a bill shows a proration of a
      discounted price: `:itemized` (the default, Stripe's recommended way: the full amount and
      the discount, as on any other line) or `:included` (the amount after the discount, with a
      discount of zero). Left out, the tenant's `:proration_discounts` applies, else `:itemized`.
    * `:description`: the payment's, the subscription's or the setup's description at the
      provider.
    * `:statement_suffix`: up to 22 letters, digits or spaces added to the line on the buyer's
      card statement, such as an order number.
    * `:submit_type`: the word on the pay button of a one-time checkout: `:pay`, `:book`,
      `:donate` or `:auto`.
    * `:expires_at`: when the checkout stops taking payment; the provider has its own limits
      (Stripe: 30 minutes to 24 hours from now). `MishkaPay.expire_checkout/3` ends it at once.
    * `:billing_address`: `:auto` (only when needed) or `:required`.
    * `:tax_id_collection`: `true` lets a business buyer give its tax id.
    * `:invoice`: in a one-time checkout, `true` makes an invoice for the payment, which the
      provider can email with the receipt; a subscription makes its own invoices.
    * `:capture`: in a one-time checkout, `:manual` only holds the money on the buyer's card: the
      payment waits as `:authorized` until `MishkaPay.capture_payment/4` takes it, all or part,
      or `MishkaPay.cancel_payment/3` lets it go. Needs `:capture`. `:automatic` (the default)
      takes it at once, the provider's recommended way (Stripe's `automatic_async`);
      `:automatic_sync` takes it at once the older way, where the provider still has one
      (Stripe's `automatic`, which answers only once the money is taken). Card holds end on their own after some days (Stripe: 7 by default).
    * `:shipping_countries`: two-letter country codes (`["NL", "DE"]`): the page asks the buyer
      for a shipping address in one of them. A subscription may ask for one too.
    * `:shipping_rates`: in a one-time checkout, the ways to ship the buyer picks from: a rate the
      provider keeps by its id (`"shr_..."`, `MishkaPay.create_shipping_rate/1`), or a new one
      as a map (`%{name: "Post", amount: %{amount: "4.95", currency: "EUR"}, min_days: 2,
      max_days: 5}`, see `MishkaPay.ShippingRate`) in the items' currency. The provider needs
      `:shipping`. A merchant of record (`:merchant_of_record`) sells no shipped goods, so
      shipping goes only with it off.

  On a platform of sellers (the provider needs `:connect`):

    * `:destination`: the seller's connected account the money goes to; the platform takes the
      sale and the provider moves it on (a destination charge).
    * `:on_behalf_of`: the connected account that is the seller of record: its country and
      statement name apply, and its fees. Usually the same account as `:destination`.
    * `:application_fee`: in a one-time checkout, the platform's cut as money, in the items'
      currency; with `:destination` it stays with the platform, and with a site's keys that name
      a connected account (a direct charge) it goes to the platform.
    * `:application_fee_percent`: in a subscription, the platform's cut of each bill, above 0
      and up to 100, two decimals at most.

  None of them goes with `mode: :setup`.

  `mode: :setup` saves a payment method for later and charges nothing; the provider needs
  `:payment_method`. It takes no `:items`, and needs a `:currency` (`"usd"`), which decides the
  payment methods the page offers. A buyer given by `customer: %{id: ...}` keeps the card;
  without one the provider makes a customer for it. Read back, the checkout brings
  `:setup_intent_id`, `:payment_method_id` and the customer's id under `:customer`. The options
  of a sale (`:trial_days`, `:discounts`, `:allow_promotion_codes`, `:automatic_tax`,
  `:merchant_of_record`, `:invoice`, `:submit_type`, `:statement_suffix`, `:card_required`) are
  refused in setup mode.

  A provider refuses an option it cannot honour (`MishkaPay.Errors.Unsupported`) rather than
  leaving it out. Which payment methods a Stripe checkout offers is set in the Stripe Dashboard.

  What the provider fills in:

    * `:id`: the provider's id of the checkout (`cs_...` at Stripe).
    * `:url`: the page to send the buyer to, with `:hosted`.
    * `:client_secret`: with `:embedded`, what the site's page gives the provider's script to
      show the form (Stripe.js `initEmbeddedCheckout`). Send it only to that buyer's browser.
    * `:status`: `:open`, `:complete` or `:expired`.
    * `:payment_id`: the payment it made, once there is one (a one-time checkout).
    * `:setup_intent_id`, `:payment_method_id`: in setup mode, the setup it made and the payment
      method it saved, once the buyer is done (`MishkaPay.fetch_payment_method/3`).
    * `:subscription_id`: the subscription it started, once there is one.
    * `:invoice_id`: the invoice it made, with `invoice: true`, once paid.
    * `:payment_link_id`: the payment link the buyer came from (`MishkaPay.PaymentLink`).
    * `:amount_total`, `:amount_tax`, `:amount_discount`: what the buyer pays in all, the tax in
      it and the discount taken off, as `Money`, once the provider has counted them (the tax may
      change as the buyer fills in an address).
    * `:shipping_address`: where the buyer asked it shipped, a `MishkaPay.Address` with the
      recipient's `:name`; `:amount_shipping`, what the chosen rate costs, and
      `:shipping_rate_id`, which rate it was.

  ## Discounts

  Each of `:discounts` is a `MishkaPay.Checkout.Discounts`, a sub_field of this struct: a coupon
  (`%{coupon_id: "SPRING"}`) or a promotion code (`%{promotion_code_id: "promo_..."}`), one of
  them. To let the buyer type a code instead, a checkout sets `allow_promotion_codes: true`; a
  checkout does one or the other.

  ## Fields

  Each of `:fields` is a `MishkaPay.Checkout.Fields`, a sub_field of this struct: a question the
  provider's page asks the buyer, such as "Name on the certificate" or "Which site is this for"
  (Stripe takes three). The answers come back on the checkout read again, in its
  `:field_values`, each field's key to the buyer's answer as the provider sent it.

    * `:key`: the caller's own name for it, letters and digits, up to 200 characters.
    * `:label`: what the buyer reads, up to 50 characters.
    * `:type`: `:text` (the default), `:numeric`, or `:dropdown` with its `:options`, from one to
      200, each a `MishkaPay.Checkout.Fields.Options` (`%{value: "pro", label: "Pro"}`).
    * `:optional`: `true` lets the buyer leave it empty.

  ## Shipping rates

  `:shipping_rates` is a conditional field: each entry is either a rate id string the provider
  keeps (`"shr_..."`), kept as the string, or a map built into a `MishkaPay.ShippingRate`.
  """

  use GuardedStruct

  alias MishkaPay.Helpers.Choice
  alias MishkaPay.Messages

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :consistent} do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :items, list(),
      structs: MishkaPay.Price,
      derives: "validate(not_nil_value, list)"

    field :ui_mode, :hosted | :embedded,
      default: :hosted,
      derives: "validate(not_nil_value, enum=Atom[hosted::embedded])",
      validator: {__MODULE__, :ui_mode}

    field :success_url, String.t(),
      derives: "sanitize(trim) validate(string)",
      validator: {__MODULE__, :return_url}

    field :cancel_url, String.t(),
      derives: "sanitize(trim) validate(string)",
      validator: {__MODULE__, :return_url}

    field :return_url, String.t(),
      derives: "sanitize(trim) validate(string)",
      validator: {__MODULE__, :return_url}

    field :capture, :automatic | :automatic_sync | :manual,
      derives: "validate(enum=Atom[automatic::automatic_sync::manual])",
      validator: {__MODULE__, :capture}

    field :customer, struct(), struct: MishkaPay.Customer

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :owner, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    field :merchant_of_record, boolean(), derives: "validate(boolean)"

    dynamic_field :metadata, validator: {__MODULE__, :metadata}

    field :id, String.t(), derives: "validate(string)"
    field :url, String.t(), derives: "validate(string)"
    field :client_secret, String.t(), derives: "validate(string)"

    field :status, :open | :complete | :expired,
      derives: "validate(enum=Atom[open::complete::expired])"

    field :mode, :payment | :subscription | :setup,
      default: :payment,
      derives: "validate(not_nil_value, enum=Atom[payment::subscription::setup])",
      validator: {__MODULE__, :mode}

    field :currency, atom(), validator: {MishkaPay.Money, :currency_field}

    field :trial_days, pos_integer(), derives: "validate(integer, min_len=1)"

    sub_field :discounts, [MishkaPay.Checkout.Discounts.t()],
      structs: true,
      authorized_fields: true,
      main_validator: {__MODULE__, :one_discount},
      derives: "validate(list)" do
      field :coupon_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :promotion_code_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    end

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
    field :terms, boolean(), derives: "validate(boolean)"
    field :phone, boolean(), derives: "validate(boolean)"

    sub_field :fields, [MishkaPay.Checkout.Fields.t()],
      structs: true,
      authorized_fields: true,
      main_validator: {__MODULE__, :field_options},
      derives: "validate(list, max_len=3)" do
      field :key, String.t(),
        enforce: true,
        derives:
          ~S"sanitize(trim) validate(not_nil_value, string, not_empty, max_len=200, regex=\A[A-Za-z0-9]+\z)"

      field :label, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=50)"

      field :type, :text | :numeric | :dropdown,
        default: :text,
        derives: "validate(not_nil_value, enum=Atom[text::numeric::dropdown])",
        validator: {__MODULE__, :field_type}

      sub_field :options, [MishkaPay.Checkout.Fields.Options.t()],
        structs: true,
        authorized_fields: true,
        derives: "validate(list, max_len=200)" do
        field :value, String.t(),
          enforce: true,
          derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=100)"

        field :label, String.t(),
          enforce: true,
          derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=100)"
      end

      field :optional, boolean(), default: false, derives: "validate(boolean)"
    end

    field :card_required, boolean(), derives: "validate(boolean)"

    field :billing_mode, :flexible | :classic,
      derives: "validate(enum=Atom[flexible::classic])",
      validator: {__MODULE__, :billing_mode}

    field :proration_discounts, :itemized | :included,
      derives: "validate(enum=Atom[itemized::included])",
      validator: {__MODULE__, :proration_discounts}

    field :description, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=500)"

    field :statement_suffix, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=22, regex=^[A-Za-z0-9 ]+$)"

    field :submit_type, :auto | :pay | :book | :donate,
      derives: "validate(enum=Atom[auto::pay::book::donate])",
      validator: {__MODULE__, :submit_type}

    field :phone_number, String.t(), derives: "validate(string)"
    dynamic_field :field_values, default: nil
    field :terms_accepted, boolean(), derives: "validate(boolean)"
    field :invoice, boolean(), derives: "validate(boolean)"
    field :invoice_id, String.t(), derives: "validate(string)"

    field :shipping_countries, list(),
      derives:
        ~S"sanitize(each=[trim, upcase]) validate(list, not_empty, each=[string, regex=\A[A-Z]{2}\z])"

    conditional_field :shipping_rates, [String.t() | MishkaPay.ShippingRate.t()],
      structs: true,
      derives: "validate(list)" do
      field :shipping_rates, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :shipping_rates, MishkaPay.ShippingRate.t(), struct: MishkaPay.ShippingRate
    end

    field :shipping_address, struct(), struct: MishkaPay.Address
    field :amount_shipping, Money.t(), validator: {MishkaPay.Money, :field}
    field :shipping_rate_id, String.t(), derives: "validate(string)"
    field :payment_link_id, String.t(), derives: "validate(string)"

    field :application_fee, Money.t(), validator: {MishkaPay.Refund, :amount}

    field :application_fee_percent, Decimal.t(), validator: {__MODULE__, :fee_percent}

    field :destination, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :on_behalf_of, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :payment_id, String.t(), derives: "validate(string)"
    field :setup_intent_id, String.t(), derives: "validate(string)"
    field :payment_method_id, String.t(), derives: "validate(string)"
    field :subscription_id, String.t(), derives: "validate(string)"
    field :amount_total, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_tax, Money.t(), validator: {MishkaPay.Money, :field}
    field :amount_discount, Money.t(), validator: {MishkaPay.Money, :field}
  end

  # Choices from JSON or a form come as strings.
  @doc false
  def customer_creation(field, value),
    do: Choice.atom(field, value, ~w(always if_required)a)

  @doc false
  def submit_type(field, value),
    do: Choice.atom(field, value, ~w(auto pay book donate)a)

  @doc false
  def billing_address(field, value),
    do: Choice.atom(field, value, ~w(auto required)a)

  @doc false
  def ui_mode(field, value),
    do: Choice.atom(field, value, ~w(hosted embedded)a)

  @doc false
  def capture(field, value),
    do: Choice.atom(field, value, ~w(automatic automatic_sync manual)a)

  @doc false
  def billing_mode(field, value),
    do: Choice.atom(field, value, ~w(flexible classic)a)

  @doc false
  def proration_discounts(field, value),
    do: Choice.atom(field, value, ~w(itemized included)a)

  @doc """
  Whether `attrs` (a caller's map) asks for proration discounts only with the flexible billing
  mode: `:proration_discounts` with `billing_mode: :classic` is an error on
  `:proration_discounts`. Checkouts and subscription schedules check it before they are built.
  """
  @spec billing(map()) :: {:ok, map()} | {:error, map()}
  def billing(attrs) do
    case {key(attrs, :billing_mode), key(attrs, :proration_discounts)} do
      {mode, discounts} when mode in [:classic, "classic"] and not is_nil(discounts) ->
        {:error,
         %{
           field: :proration_discounts,
           action: :billing_mode,
           message: Messages.text(:proration_discounts_flexible)
         }}

      _fits ->
        {:ok, attrs}
    end
  end

  # A checkout that expires is one that has not expired yet.
  @doc false
  def later(field, %DateTime{} = at) do
    case DateTime.compare(at, DateTime.utc_now()) do
      :gt -> {:ok, field, at}
      _past -> {:error, field, Messages.text(:expires_past)}
    end
  end

  def later(field, at), do: {:ok, field, at}

  # A share of each bill, above 0 and up to 100, with at most two decimals, as a number or its
  # text.
  @doc false
  def fee_percent(field, nil), do: {:ok, field, nil}

  def fee_percent(field, value) when is_float(value),
    do: fee_percent(field, Decimal.from_float(value))

  def fee_percent(field, value) do
    with {:ok, percent} <- Decimal.cast(value),
         true <- Decimal.gt?(percent, 0) and not Decimal.gt?(percent, 100),
         true <- Decimal.equal?(percent, Decimal.round(percent, 2)) do
      {:ok, field, Decimal.normalize(percent)}
    else
      _not_a_share -> {:error, field, Messages.text(:fee_percent)}
    end
  end

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
  def mode(:mode, mode) when is_binary(mode),
    do: MishkaPay.Helpers.Choice.atom(:mode, mode, ~w(payment subscription setup)a)

  def mode(:mode, mode), do: {:ok, :mode, mode}

  @doc false
  def field_type(field, value), do: Choice.atom(field, value, ~w(text numeric dropdown)a)

  # A dropdown question has its options; the other types none. The options themselves are the
  # `options` sub_field's.
  @doc false
  def field_options(attrs) do
    case {attrs |> key(:type) |> to_string(), key(attrs, :options)} do
      {"dropdown", [_ | _]} -> {:ok, attrs}
      {"dropdown", _none} -> options_error()
      {_other, none} when none in [nil, []] -> {:ok, attrs}
      {_other, _options} -> options_error()
    end
  end

  defp options_error,
    do: {:error, %{field: :options, action: :options, message: Messages.text(:dropdown_options)}}

  # A discount the checkout applies is a coupon or a promotion code, one of them.
  @doc false
  def one_discount(attrs) do
    case {is_binary(attrs[:coupon_id]), is_binary(attrs[:promotion_code_id])} do
      {true, false} ->
        {:ok, attrs}

      {false, true} ->
        {:ok, attrs}

      _none_or_both ->
        {:error,
         %{field: :coupon_id, action: :discount, message: Messages.text(:discount_one_of)}}
    end
  end

  # One currency across the items, and items that fit the mode: recurring prices for a
  # subscription, one-time prices for a payment. Runs before the items are built, so an item may
  # still be a map from JSON, with string keys. An items list that failed to build is already
  # reported on its own.
  @doc false
  def consistent(attrs) do
    with {:ok, attrs} <- urls_mode(attrs),
         {:ok, attrs} <- for_mode(attrs),
         {:ok, attrs} <- one_buyer(attrs),
         {:ok, attrs} <- one_discount_way(attrs),
         {:ok, attrs} <- customer_creation_mode(attrs),
         {:ok, attrs} <- invoice_mode(attrs),
         {:ok, attrs} <- options_mode(attrs),
         {:ok, attrs} <- billing_mode_of_plan(attrs),
         {:ok, attrs} <- fee_mode(attrs),
         {:ok, attrs} <- shipping_mode(attrs),
         do: fits_mode(attrs)
  end

  # A sale has items in one currency; a setup checkout has none (an empty list), and a currency
  # of its own.
  defp for_mode(attrs) do
    case {key(attrs, :mode) in [:setup, "setup"], key(attrs, :currency)} do
      {true, _currency} ->
        setup(attrs)

      {false, nil} ->
        one_currency(attrs)

      {false, _currency} ->
        {:error, %{field: :currency, action: :mode, message: Messages.text(:currency_setup_only)}}
    end
  end

  @sale_only [
    :items,
    :trial_days,
    :discounts,
    :allow_promotion_codes,
    :automatic_tax,
    :merchant_of_record,
    :invoice,
    :submit_type,
    :statement_suffix,
    :card_required,
    :application_fee,
    :application_fee_percent,
    :destination,
    :on_behalf_of
  ]

  defp setup(attrs) do
    case {Enum.find(@sale_only, &(given(attrs, &1) not in [nil, []])), key(attrs, :currency)} do
      {nil, nil} ->
        {:error, %{field: :currency, action: :mode, message: Messages.text(:setup_currency)}}

      {nil, _currency} ->
        {:ok, Map.put(attrs, :items, [])}

      {field, _currency} ->
        {:error,
         %{field: field, action: :mode, message: Messages.text(:setup_takes_no, param: field)}}
    end
  end

  # A hosted checkout comes back to its success or cancel page; an embedded one to its return
  # page only.
  defp urls_mode(attrs) do
    wrong =
      if key(attrs, :ui_mode) in [:embedded, "embedded"],
        do: [:success_url, :cancel_url],
        else: [:return_url]

    case Enum.find(wrong, &key(attrs, &1)) do
      nil -> {:ok, attrs}
      field -> {:error, page_error(field)}
    end
  end

  @doc """
  Whether built `checkout` has the pages its `:ui_mode` needs: `:success_url` and `:cancel_url`
  when hosted, `:return_url` when embedded. `MishkaPay.checkout/1` checks it after the build, so
  a page given and refused is reported once, by its own field.
  """
  @spec pages(t()) :: :ok | {:error, Splode.Error.t()}
  def pages(%__MODULE__{} = checkout) do
    needed =
      if checkout.ui_mode == :embedded, do: [:return_url], else: [:success_url, :cancel_url]

    case Enum.find(needed, &is_nil(Map.get(checkout, &1))) do
      nil -> :ok
      field -> MishkaPay.Errors.from_builder({:error, [page_error(field)]})
    end
  end

  defp page_error(field),
    do: %{field: field, action: :ui_mode, message: Messages.text(:ui_mode_urls)}

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

  # A trial without a card is a subscription's, the button's word a
  # one-time checkout's.
  defp options_mode(attrs) do
    subscription? = key(attrs, :mode) in [:subscription, "subscription"]

    cond do
      given(attrs, :card_required) == false and not subscription? ->
        {:error,
         %{
           field: :card_required,
           action: :mode,
           message: Messages.text(:recurring_only, param: "card_required")
         }}

      key(attrs, :capture) in [:manual, "manual"] and subscription? ->
        {:error,
         %{
           field: :capture,
           action: :mode,
           message: Messages.text(:one_time_only, param: "capture")
         }}

      not is_nil(key(attrs, :submit_type)) and subscription? ->
        {:error,
         %{
           field: :submit_type,
           action: :mode,
           message: Messages.text(:one_time_only, param: "submit_type")
         }}

      true ->
        {:ok, attrs}
    end
  end

  # A billing mode is a subscription's, set when it is made.
  defp billing_mode_of_plan(attrs) do
    case {key(attrs, :mode) in [:subscription, "subscription"],
          Enum.find([:billing_mode, :proration_discounts], &key(attrs, &1))} do
      {false, field} when not is_nil(field) ->
        {:error,
         %{
           field: field,
           action: :mode,
           message: Messages.text(:recurring_only, param: Atom.to_string(field))
         }}

      _plan_or_none ->
        billing(attrs)
    end
  end

  # A platform's cut is money on a one-time sale and a share of each bill on a subscription.
  defp fee_mode(attrs) do
    subscription? = key(attrs, :mode) in [:subscription, "subscription"]

    case {subscription?, key(attrs, :application_fee), key(attrs, :application_fee_percent)} do
      {true, fee, _percent} when not is_nil(fee) ->
        {:error,
         %{
           field: :application_fee,
           action: :mode,
           message: Messages.text(:one_time_only, param: "application_fee")
         }}

      {false, _fee, percent} when not is_nil(percent) ->
        {:error,
         %{
           field: :application_fee_percent,
           action: :mode,
           message: Messages.text(:recurring_only, param: "application_fee_percent")
         }}

      _fits ->
        {:ok, attrs}
    end
  end

  # Shipping rates are a one-time checkout's, and no merchant of record ships goods.
  defp shipping_mode(attrs) do
    shipping? = key(attrs, :shipping_rates) not in [nil, []]

    cond do
      shipping? and key(attrs, :mode) in [:subscription, "subscription"] ->
        {:error,
         %{
           field: :shipping_rates,
           action: :mode,
           message: Messages.text(:one_time_only, param: "shipping_rates")
         }}

      (shipping? or key(attrs, :shipping_countries) not in [nil, []]) and
          key(attrs, :merchant_of_record) == true ->
        {:error,
         %{
           field: :merchant_of_record,
           action: :shipping,
           message: Messages.text(:managed_payments_shipping)
         }}

      true ->
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

  # A value as given, `false` too, which `key/2` reads as absent.
  defp given(%{} = attrs, name) do
    case Map.fetch(attrs, name) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(name))
    end
  end

  defp one_currency(%{items: []}),
    do: {:error, %{field: :items, action: :items, message: Messages.text(:items_empty)}}

  defp one_currency(%{items: items} = attrs) when is_list(items) do
    rates = Enum.filter(List.wrap(key(attrs, :shipping_rates)), &is_map/1)

    case (items ++ rates) |> MapSet.new(&currency/1) |> MapSet.delete(nil) |> MapSet.size() do
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
