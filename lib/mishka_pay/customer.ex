# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Customer do
  @moduledoc """
  A buyer the provider keeps: who they are, so a returning buyer pays without typing their details
  again and their payments, invoices and subscriptions hang off one record. A guarded_struct.

  At Stripe a customer is an account with the customer configuration (Accounts v2, `acct_...`, the
  default) or a Customer (`/v1/customers`, `cus_...`), as the call's `:api` or the tenant's
  `:customer_api` (`MishkaPay.Credentials`) says. Every call that takes a customer id takes
  either kind.

  Made with `MishkaPay.create_customer/1`, changed with `MishkaPay.update_customer/1`, read with
  `MishkaPay.fetch_customer/3` and `MishkaPay.list_customers/3`. A host keeps the customer's `:id`
  on its own user or account.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:api`: which of the provider's APIs makes it, `:v2` or `:v1` (Stripe's Accounts v2 or its
      Customers); left out, the tenant's `:customer_api` setting (`:v2` by default). A read
      answers the API it was read with: a customer is read, changed and deleted with the API its
      id belongs to.
    * `:email`, `:name`, `:phone`: the buyer's details.
    * `:address`: where the buyer lives, a `MishkaPay.Address` (their billing address).
    * `:default_payment_method`: the payment method future invoices are paid with (`pm_...`),
      one the customer already keeps.
    * `:reference`: the host's own id for the buyer (a user id); it makes the idempotency key, so
      the same reference never makes two customers, and it comes back on the customer.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id`, `:created_at`.

  In a checkout, `customer: %{id: "acct_..."}` (or `"cus_..."`) sells to a known customer and
  `customer: %{email: "..."}` fills in the email for a new buyer: one or the other
  (`MishkaPay.Checkout`).
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :email, String.t(), derives: "sanitize(trim, downcase) validate(string, email_r)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=250)"
    field :phone, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=30)"
    field :address, struct(), struct: MishkaPay.Address

    field :api, :v2 | :v1,
      derives: "validate(enum=Atom[v2::v1])",
      validator: {MishkaPay.ConnectedAccount, :api}

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :default_payment_method, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

defmodule MishkaPay.Customer.BalanceTransaction do
  @moduledoc """
  One change of a customer's balance at the provider: store credit given, a debit added, or
  credit used on a bill. Made with `MishkaPay.adjust_customer_balance/5` and listed with
  `MishkaPay.list_customer_balance/4`. A guarded_struct.

  The sign is the provider's: below zero is credit, money the seller owes the customer, taken off
  their next bills; above zero is a debit added to their next bill. At Stripe a customer's
  balance is in one currency.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:customer_id`: the provider customer.
    * `:amount`: a `Money`, below zero to give credit.
    * `:description`: why, for the seller and the customer.
    * `:reference`: the caller's own id for this change, such as a support ticket. It makes the
      idempotency key, so the same reference never changes the balance twice, and it comes back
      on it.

  What the provider fills in: `:id` (`cbtxn_...` at Stripe), `:ending_balance` (the balance after
  it), `:type` (its own name for it, such as `"adjustment"` or `"applied_to_invoice"`),
  `:invoice_id` when a bill used it, and `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :customer_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :amount, Money.t(), enforce: true, validator: {MishkaPay.Money, :signed_field}

    field :description, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=350)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :id, String.t(), derives: "validate(string)"
    field :ending_balance, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :type, String.t(), derives: "validate(string)"
    field :invoice_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

defmodule MishkaPay.Customer.TaxId do
  @moduledoc """
  A business buyer's tax id kept on a provider customer (`txi_...` at Stripe), such as an EU VAT
  number. The provider prints it on the customer's invoices, and a provider that counts the tax
  (Stripe Tax) may then charge no VAT and note a reverse charge. A guarded_struct.

  Added with `MishkaPay.create_tax_id/4`, listed with `MishkaPay.list_tax_ids/4` and removed with
  `MishkaPay.delete_tax_id/4`.

  What the caller gives:

    * `:type`: the provider's kind of tax id, such as `"eu_vat"`, `"gb_vat"`, `"au_abn"` or
      `"us_ein"` (Stripe lists them all at docs.stripe.com/billing/customer/tax-ids).
    * `:value`: the number itself, such as `"DE123456789"`.

  What the provider fills in:

    * `:id`, `:customer_id`, `:created_at`.
    * `:country`: the two-letter country the tax id belongs to.
    * `:verification`: `:pending`, `:verified`, `:unverified` or `:unavailable`, for the kinds a
      provider checks against a government register (EU VAT, GB VAT and AU ABN at Stripe); `nil`
      for the others, whose format alone is checked. A check runs after the tax id is added: the
      provider sends `customer.tax_id.updated` when it ends.
    * `:verified_name`, `:verified_address`: what the register holds for the number.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :type, String.t(),
      derives:
        "sanitize(trim, downcase) validate(string, not_empty, max_len=20, regex=^[a-z][a-z_]*$)"

    field :value, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=100)"
    field :country, String.t(), derives: "validate(string)"

    field :verification, :pending | :verified | :unverified | :unavailable,
      derives: "validate(enum=Atom[pending::verified::unverified::unavailable])"

    field :verified_name, String.t(), derives: "validate(string)"
    field :verified_address, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

defmodule MishkaPay.Customer.PaymentMethod do
  @moduledoc """
  A payment method a customer saved at the provider (`pm_...` at Stripe), such as a card, so a
  later invoice or subscription charges it without the buyer typing it again. A guarded_struct
  the provider fills in.

  A checkout in `mode: :setup` saves one (`MishkaPay.Checkout`). Read with
  `MishkaPay.fetch_payment_method/3` and `MishkaPay.list_payment_methods/3`, made the customer's
  default with `MishkaPay.set_default_payment_method/4`, and taken off the customer with
  `MishkaPay.detach_payment_method/3`.

    * `:provider`: which provider keeps it.
    * `:id`: the provider's id of the payment method.
    * `:customer_id`: the customer it is saved on; `nil` once it is taken off.
    * `:type`: the provider's kind of payment method, such as `"card"` or `"sepa_debit"`.
    * `:card_brand`, `:card_last4`, `:card_exp_month`, `:card_exp_year`: for a card, its brand
      (`"visa"`), its last four digits and when it expires; `nil` for other kinds.
    * `:created_at`: when it was saved.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string, not_empty)"
    field :id, String.t(), derives: "validate(string, not_empty)"
    field :customer_id, String.t(), derives: "validate(string)"
    field :type, String.t(), derives: "validate(string)"
    field :card_brand, String.t(), derives: "validate(string)"
    field :card_last4, String.t(), derives: "validate(string)"
    field :card_exp_month, pos_integer(), derives: "validate(integer)"
    field :card_exp_year, pos_integer(), derives: "validate(integer)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
