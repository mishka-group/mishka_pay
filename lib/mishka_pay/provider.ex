# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Provider do
  @moduledoc """
  Every payment provider, Stripe included, implements these callbacks. A provider is one module:

      defmodule MyApp.Pay.Acme do
        use MishkaPay.Provider, id: "acme", label: "Acme Pay"
        # the callbacks below
      end

  `use` makes the module a mishka_installer plugin on `mishka_pay:providers`, so supervising it
  installs the provider and stopping its plugin takes it out. A project adds its own payment method
  the same way, without changing Mishka Pay.

  Callbacks (stage 1 writes them):

    * `id/0`, `label/0`: who the provider is.
    * `capabilities/0`: what it can do (checkout, refund, subscriptions, webhooks or a return URL with
      a verify call). A call the provider cannot do answers `{:error, :unsupported}`.
    * `checkout/2`, `fetch_payment/2`, `refund/2`: the operations, each taking a guarded_struct and the
      site's credentials.
    * `verify_webhook/3`: checks a provider's signed message and turns it into a `MishkaPay.Event`.
  """
end
