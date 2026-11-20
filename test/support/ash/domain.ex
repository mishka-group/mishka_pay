# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Domain do
  @moduledoc "A host's payments domain, holding the resources the Ash layer tests use."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource MishkaPay.Support.WebhookEvent
    resource MishkaPay.Support.WebhookRejection
    resource MishkaPay.Support.Payment
    resource MishkaPay.Support.Subscription
    resource MishkaPay.Support.Customer
    resource MishkaPay.Support.Dispute
    resource MishkaPay.Support.SitePayment
    resource MishkaPay.Support.Member
    resource MishkaPay.Support.SiteSubscription
    resource MishkaPay.Support.MembersPost
    resource MishkaPay.Support.SiteProduct
    resource MishkaPay.Support.SitePrice
    resource MishkaPay.Support.SiteCoupon
    resource MishkaPay.Support.SitePromotionCode
    resource MishkaPay.Support.SitePaymentLink
    resource MishkaPay.Support.SiteInvoice
  end
end
