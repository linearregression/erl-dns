%% Copyright (c) 2014, SiftLogic LLC
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(erldns_storage_json).

%% API
-export([create/1,
         insert/2,
         delete_table/1,
         delete/2,
         backup_table/1,
         backup_tables/0,
         select/2,
         select/3,
         foldl/3,
         empty_table/1,
         list_table/1]).

%% Public API
%% @doc Create ets table wrapper. Use match cases for adding different options to the table.
-spec create(atom()) -> ok | not_implemented | {error, Reason :: term()}.
create(schema) ->
    not_implemented;
create(Name = zones) ->
    create_ets_table(Name, set);
create(Name = authorities) ->
    create_ets_table(Name, set);
%% These tables should always use ets. Due to their functionality
create(Name = packet_cache) ->
    create_ets_table(Name, set);
create(Name = host_throttle) ->
    create_ets_table(Name, set);
create(Name = lookup_table) ->
    create_ets_table(Name, bag);
create(Name = handler_registry) ->
    create_ets_table(Name, set).

%% @doc Insert value in ets table.
-spec insert(atom(), tuple()) -> ok | {error, Reason :: term()}.
insert(Table, Value)->
    case ets:insert(Table, Value) of
        true ->
            ok;
        Error ->
            {error, Error}
    end.

%% @doc Delete entire ets table.
-spec delete_table(atom()) -> ok | {error, Reason :: term()}.
delete_table(Table)->
    case ets:delete(Table) of
        true ->
            ok;
        Error ->
            {error, Error}
    end.

%% @doc Delete an entry in the ets table.Ets always returns true for this function.
-spec delete(atom(), term()) -> ok.
delete(Table, Key) ->
    ets:delete(Table, Key),
    ok.

%% @doc Backup a specific ets table.
%% @see https://github.com/SiftLogic/erl-dns/issues/3
-spec backup_table(atom()) -> ok | {error, Reason :: term()}.
backup_table(_Table)->
    {error, not_implemented}.

%% @doc Should backup all ets tables.
%% @see https://github.com/SiftLogic/erl-dns/issues/3
-spec backup_tables() -> ok | {error, Reason :: term()}.
backup_tables() ->
    {error, not_implemented}.

%% @doc Select from ets using key, value.
-spec select(atom(), term()) -> tuple().
select(Table, Key) ->
    ets:lookup(Table, Key).

%% @doc Select from ets using match specs.
-spec select(atom(), list(), integer()) -> tuple() | '$end_of_table'.
select(Table, MatchSpec, Limit) ->
    ets:select(Table, MatchSpec, Limit).

%% @doc Wrapper for foldl in ets.
-spec foldl(fun(), list(), atom())  -> Acc :: term() | {error, Reason :: term()}.
foldl(Fun, Acc, Table) ->
    ets:foldl(Fun, Acc, Table).

%% @doc Empty ets table. Ets always returns true for this function.
-spec empty_table(atom()) -> ok.
empty_table(Table) ->
    ets:delete_all_objects(Table),
    ok.

%% @doc Lists the ets table
-spec list_table(atom()) -> term() | {error, term()}.
list_table(TableName) ->
    try ets:tab2list(TableName)
    catch
        error:R ->
            {error, R}
    end.

%% Internal methods
-spec create_ets_table(ets:tab(), ets:type()) -> ok | {error, Reason :: term()}.
create_ets_table(Name, Type) ->
  case ets:info(Name) of
    undefined ->
      case ets:new(Name, [Type, public, named_table]) of
        Name ->
          ok;
        Error ->
          {error, Error}
      end;
    _InfoList ->
      ok
  end.
