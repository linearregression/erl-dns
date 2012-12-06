-module(erldns_zone_cache).

-behavior(gen_server).

-include("dns.hrl").
-include("erldns.hrl").

% API
-export([start_link/0, find_zone/1, find_zone/2, get_zone/1, put_zone/2, get_authority/1, put_authority/2, get_delegations/1, get_records_by_name/1, in_zone/1]).

% Internal API
-export([build_named_index/1]).

% Gen server hooks
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
       ]).

-define(SERVER, ?MODULE).

-record(state, {zones, authorities}).

%% Public API
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

find_zone(Qname) ->
  lager:info("Finding zone for name ~p", [Qname]),
  Authority = erldns_metrics:measure(none, ?MODULE, get_authority, [Qname]),
  find_zone(normalize_name(Qname), Authority).

find_zone(Qname, {error, _}) -> find_zone(Qname, []);
find_zone(Qname, {ok, Authority}) -> find_zone(Qname, Authority);
find_zone(_Qname, []) ->
  {error, not_authoritative};
find_zone(Qname, Authorities) when is_list(Authorities) ->
  lager:info("Finding zone ~p (Authorities: ~p)", [Qname, Authorities]),
  Authority = lists:last(Authorities),
  find_zone(Qname, Authority);

find_zone(Qname, Authority) when is_record(Authority, dns_rr) ->
  lager:info("Finding zone ~p (Authority: ~p)", [Qname, Authority]),
  Name = normalize_name(Qname),
  case dns:dname_to_labels(Name) of
    [] -> {error, zone_not_found};
    [_] -> {error, zone_not_found};
    [_|Labels] ->
      case erldns_metrics:measure(none, erldns_zone_cache, get_zone, [Name]) of
        {ok, Zone} -> Zone;
        {error, zone_not_found} ->
          case Name =:= Authority#dns_rr.name of
            true -> make_zone(Name);
            false -> find_zone(dns:labels_to_dname(Labels), Authority)
          end
      end
  end.

get_zone(Name) ->
  gen_server:call(?SERVER, {get, Name}).

put_zone(Name, Zone) ->
  gen_server:call(?SERVER, {put, Name, Zone}).

get_authority(Message) when is_record(Message, dns_message) ->
  case Message#dns_message.questions of
    [] -> [];
    Questions -> 
      Question = lists:last(Questions),
      get_authority(Question#dns_query.name)
  end;
get_authority(Name) ->
  gen_server:call(?SERVER, {get_authority, Name}).

put_authority(Name, Authority) ->
  gen_server:call(?SERVER, {put_authority, Name, Authority}).

get_delegations(Name) ->
  Result = gen_server:call(?SERVER, {get_delegations, Name}),
  lager:info("get_delegations(~p): ~p", [Name, Result]),
  case Result of
    {ok, Delegations} -> Delegations;
    _ -> []
  end.

get_records_by_name(Name) ->
  gen_server:call(?SERVER, {get_records_by_name, Name}).

in_zone(Name) ->
  gen_server:call(?SERVER, {in_zone, Name}).

%% Gen server hooks
init([]) ->
  Zones = dict:new(),
  Authorities = dict:new(),
  {ok, #state{zones = Zones, authorities = Authorities}}.

handle_call({get, Name}, _From, State) ->
  case dict:find(normalize_name(Name), State#state.zones) of
    {ok, Zone} -> {reply, {ok, Zone#zone{name = normalize_name(Name), records = [], records_by_name=trimmed}}, State};
    _ -> {reply, {error, zone_not_found}, State}
  end;

handle_call({get_delegations, Name}, _From, State) ->
  case find_zone_in_cache(Name, State) of
    {ok, Zone} ->
      Records = lists:filter(fun(R) -> apply(match_type(?DNS_TYPE_NS), [R]) and apply(match_glue(Name), [R]) end, Zone#zone.records),
      {reply, {ok, Records}, State};
    Response ->
      lager:info("Failed to get zone for ~p: ~p", [Name, Response]),
      {reply, Response, State}
  end;

handle_call({put, Name, Zone}, _From, State) ->
  Zones = dict:store(normalize_name(Name), Zone, State#state.zones),
  {reply, ok, State#state{zones = Zones}};

handle_call({get_authority, Name}, _From, State) ->
  case dict:find(normalize_name(Name), State#state.authorities) of
    {ok, Authority} -> {reply, {ok, Authority}, State};
    _ -> 
      case load_authority(Name) of
        [] -> {reply, {error, authority_not_found}, State};
        Authority ->
          Authorities = dict:store(normalize_name(Name), Authority, State#state.authorities),
          {reply, {ok, Authority}, State#state{authorities = Authorities}}
      end
  end;

handle_call({put_authority, Name, Authority}, _From, State) ->
  Authorities = dict:store(normalize_name(Name), Authority, State#state.authorities),
  {reply, ok, State#state{authorities = Authorities}};

handle_call({get_records_by_name, Name}, _From, State) ->
  case find_zone_in_cache(Name, State) of
    {ok, Zone} ->
      case dict:find(normalize_name(Name), Zone#zone.records_by_name) of
        {ok, RecordSet} -> {reply, RecordSet, State};
        _ -> {reply, [], State}
      end;
    Response ->
      lager:info("Failed to get zone: ~p", [Response]),
      {reply, [], State}
  end;

handle_call({in_zone, Name}, _From, State) ->
  case find_zone_in_cache(Name, State) of
    {ok, Zone} ->
      {reply, internal_in_zone(Name, Zone), State};
    _ ->
      {reply, false, State}
  end.

handle_cast(_Message, State) ->
  {noreply, State}.
handle_info(_Message, State) ->
  {noreply, State}.
terminate(_Reason, _State) ->
  ok.
code_change(_PreviousVersion, State, _Extra) ->
  {ok, State}.

% Internal API%

internal_in_zone(Name, Zone) ->
  case dict:is_key(normalize_name(Name), Zone#zone.records_by_name) of
    true -> true;
    false ->
      case dns:dname_to_labels(Name) of
        [] -> false;
        [_] -> false;
        [_|Labels] -> internal_in_zone(dns:labels_to_dname(Labels), Zone)
      end
  end.

load_authority(Qname) ->
  load_authority(Qname, [F([normalize_name(Qname)]) || F <- soa_functions()]).

load_authority(_Qname, []) -> [];
load_authority(_Qname, Authorities) ->
  lists:last(Authorities).

find_zone_in_cache(Qname, State) ->
  Name = normalize_name(Qname),
  case dns:dname_to_labels(Name) of
    [] -> {error, zone_not_found};
    [_] -> {error, zone_not_found};
    [_|Labels] ->
      case dict:find(Name, State#state.zones) of
        {ok, Zone} -> {ok, Zone};
        error -> find_zone_in_cache(dns:labels_to_dname(Labels), State)
      end
  end.

make_zone(Qname) ->
  lager:info("Constructing new zone for ~p", [Qname]),
  DbRecords = erldns_metrics:measure(Qname, erldns_pgsql, lookup_records, [normalize_name(Qname)]),
  Records = lists:usort(lists:flatten(lists:map(fun(R) -> erldns_pgsql_responder:db_to_record(Qname, R) end, DbRecords))),
  RecordsByName = erldns_metrics:measure(Qname, ?MODULE, build_named_index, [Records]),
  Authorities = lists:filter(match_type(?DNS_TYPE_SOA), Records),
  Zone = #zone{record_count = length(Records), authority = Authorities, records = Records, records_by_name = RecordsByName},
  erldns_zone_cache:put_zone(Qname, Zone),
  Zone.

build_named_index(Records) -> build_named_index(Records, dict:new()).
build_named_index([], Idx) -> Idx;
build_named_index([R|Rest], Idx) ->
  case dict:find(R#dns_rr.name, Idx) of
    {ok, Records} ->
      build_named_index(Rest, dict:store(R#dns_rr.name, Records ++ [R], Idx));
    error -> build_named_index(Rest, dict:store(R#dns_rr.name, [R], Idx))
  end.

normalize_name(Name) when is_list(Name) -> string:to_lower(Name);
normalize_name(Name) when is_binary(Name) -> list_to_binary(string:to_lower(binary_to_list(Name))).

%% Build a list of functions for looking up SOA records based on the
%% registered responders.
soa_functions() ->
  lists:map(fun(M) -> fun M:get_soa/1 end, erldns_handler:get_responder_modules()).

%% Various matching functions.
match_type(Type) -> fun(R) when is_record(R, dns_rr) -> R#dns_rr.type =:= Type end.
%match_wildcard() -> fun(R) when is_record(R, dns_rr) -> lists:any(fun(L) -> L =:= <<"*">> end, dns:dname_to_labels(R#dns_rr.name)) end.
match_glue(Name) -> fun(R) when is_record(R, dns_rr) -> R#dns_rr.data =:= #dns_rrdata_ns{dname=Name} end.
