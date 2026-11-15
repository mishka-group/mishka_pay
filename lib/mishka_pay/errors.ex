# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors do
  @moduledoc """
  Every error Mishka Pay returns, built with [Splode](https://hex.pm/packages/splode), the error
  library Ash is built on.

  | Class | Module | When |
  |---|---|---|
  | `:invalid` | `MishkaPay.Errors.Invalid` | the input is wrong: a guarded_struct validation error, for example |
  | `:provider` | `MishkaPay.Errors.Provider` | the provider refused or cannot do it: `Declined`, `Unsupported` |
  | `:unknown` | `MishkaPay.Errors.Unknown` | anything else, as an `UnknownError` |

  guarded_struct's errors (`GuardedStruct.Errors`) are merged in, so a failed `builder/1` joins
  Mishka Pay's own errors with no conversion:

      {:error, errors} = MishkaPay.Checkout.builder(params)

      [GuardedStruct.Errors.from_tuple(errors), MishkaPay.Errors.Unsupported.exception(provider: "acme", operation: :refund)]
      |> MishkaPay.Errors.to_class()

  When errors of several classes are combined, the class listed first in `error_classes` wins.
  """

  use Splode,
    error_classes: [
      invalid: MishkaPay.Errors.Invalid,
      provider: MishkaPay.Errors.Provider,
      unknown: MishkaPay.Errors.Unknown
    ],
    unknown_error: MishkaPay.Errors.UnknownError,
    merge_with: [GuardedStruct.Errors]
end
