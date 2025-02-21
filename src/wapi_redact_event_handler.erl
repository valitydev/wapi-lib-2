-module(wapi_redact_event_handler).

-export([new/2]).

-behaviour(woody_event_handler).
-export([handle_event/4]).

-type secret() :: binary().
-type options() :: {[secret()], woody:ev_handlers()}.

-spec new([secret()], woody:ev_handlers()) ->
    woody:handler(options()).
new(Secrets, Handlers) ->
    {?MODULE, {lists:usort(Secrets), Handlers}}.

-spec handle_event(Event, RpcID, Meta, Opts) -> ok when
    Event :: woody_event_handler:event(),
    RpcID :: woody:rpc_id() | undefined,
    Meta :: woody_event_handler:event_meta(),
    Opts :: options().
handle_event(Event, RpcID, Meta, {Secrets, Handlers}) ->
    FilteredMeta = filter_meta(Meta, Secrets),
    woody_event_handler:handle_event(Handlers, Event, RpcID, FilteredMeta).

-define(REDACTED, <<"***">>).
-define(FALLBACK, <<"*FALLBACK*">>).

filter_meta(Meta, Secrets) ->
    maps:map(fun(Name, Value) -> filter(Name, Value, Secrets) end, Meta).

filter(Meta, Value, Secrets) when
    Meta == args;
    Meta == result;
    Meta == reason;
    Meta == error;
    Meta == stack
->
    filter(Value, Secrets);
filter(_, Value, _Secrets) ->
    Value.

%% common
filter(L, Secrets) when is_list(L) ->
    [filter(E, Secrets) || E <- L];
filter(T, Secrets) when is_tuple(T) ->
    list_to_tuple(filter(tuple_to_list(T), Secrets));
filter(M, Secrets) when is_map(M) ->
    genlib_map:truemap(fun(K, V) -> {filter(K, Secrets), filter(V, Secrets)} end, M);
filter(B, Secrets) when is_binary(B) ->
    binary:replace(B, Secrets, ?REDACTED, [global]);
filter(V, _) when is_atom(V) ->
    V;
filter(V, _) when is_number(V) ->
    V;
filter(P, _) when is_pid(P) ->
    P;
filter(P, _) when is_port(P) ->
    P;
filter(F, _) when is_function(F) ->
    F;
filter(R, _) when is_reference(R) ->
    R;
%% NOTE
%% Fallback. Notably covers «bitstrings-but-not-binaries» which are unexpected in
%% the context of Woody RPC anyway.
filter(_V, _) ->
    ?FALLBACK.
