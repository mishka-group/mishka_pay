# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Page do
  @moduledoc """
  One page of a list: what every `MishkaPay.list_*` call answers. A guarded_struct.

    * `:items`: the structs of this page, newest first.
    * `:has_more`: whether the provider has more after this page.
    * `:next`: the cursor of the next page, `nil` on the last one. Pass it back as `after:`.

  Every list call takes `limit:` (1 to 100, 10 by default) and `after:` (a page's `:next`):

      {:ok, page} = MishkaPay.list_customers("stripe", site_id, limit: 50)
      {:ok, more} = MishkaPay.list_customers("stripe", site_id, limit: 50, after: page.next)

  `stream/1` pages through everything, one request per page and only as far as it is read:

      "stripe"
      |> then(&fn opts -> MishkaPay.list_products(&1, site_id, opts) end)
      |> MishkaPay.Page.stream()
      |> Enum.take(250)
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :items, list(), default: [], derives: "validate(list)"
    field :has_more, boolean(), default: false, derives: "validate(boolean)"
    field :next, String.t(), derives: "validate(string, not_empty)"
  end

  @doc """
  A lazy stream of every item a list call gives, page by page. `list` is a function of the list
  options (`after:` is set from the page before) answering `{:ok, %MishkaPay.Page{}}`. A list that
  answers an error raises it, a `MishkaPay.Errors` exception, where the stream is read.
  """
  @spec stream((keyword() -> {:ok, t()} | {:error, Exception.t()})) :: Enumerable.t()
  def stream(list) when is_function(list, 1) do
    Stream.resource(
      fn -> [] end,
      fn
        :done ->
          {:halt, :done}

        opts ->
          case list.(opts) do
            {:ok, %__MODULE__{items: items, has_more: true, next: next}} when is_binary(next) ->
              {items, [after: next]}

            {:ok, %__MODULE__{items: items}} ->
              {items, :done}

            {:error, error} ->
              raise error
          end
      end,
      fn _state -> :ok end
    )
  end
end
