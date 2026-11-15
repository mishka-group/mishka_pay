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

      MishkaPay.Errors.from_builder(MishkaPay.Money.builder(%{amount: -1, currency: "usd"}))
      #=> {:error, %MishkaPay.Errors.Invalid{errors: [%GuardedStruct.Errors.Validation{field: :amount}]}}

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

  @doc """
  A guarded_struct `builder/1` answer with its errors as Mishka Pay's: `{:ok, struct}` stays, and
  `{:error, list}` becomes `{:error, %MishkaPay.Errors.Invalid{}}` holding guarded_struct's
  validation errors.
  """
  @spec from_builder({:ok, struct()} | {:error, list()}) ::
          {:ok, struct()} | {:error, Splode.Error.t()}
  def from_builder({:ok, _struct} = ok), do: ok

  # guarded_struct's own class is unwrapped first: Splode leaves a class error of a merged library as
  # it is, so only its errors are re-classed here.
  def from_builder({:error, errors}) when is_list(errors) do
    %{errors: validations} = GuardedStruct.Errors.from_tuple(errors)
    {:error, to_class(validations)}
  end
end
