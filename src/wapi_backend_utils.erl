-module(wapi_backend_utils).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_identity_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wallet_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("fistful_proto/include/fistful_w2w_transfer_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_thrift.hrl").

-define(EXTERNAL_ID, <<"externalID">>).
-define(CTX_NS, <<"wapi">>).
-define(BENDER_DOMAIN, <<"wapi">>).
-define(BENDER_SCHEMA_VER1, 1).

%% Context
-type context() :: #{namespace() => md()}.
-type namespace() :: binary().
%% as stolen from `machinery_msgpack`
-type md() ::
    nil
    | boolean()
    | integer()
    | float()
    %% string
    | binary()
    %% binary
    | {binary, binary()}
    | [md()]
    | #{md() => md()}.

-type handler_context() :: wapi_handler_utils:handler_context().
-type id() :: binary().
-type hash() :: integer().
-type params() :: map().
-type gen_type() ::
    identity
    | identity_challenge
    | wallet
    | destination
    | withdrawal
    | w2w_transfer.
-type entity_type() ::
    identity
    | wallet
    | destination
    | withdrawal
    | w2w_transfer.
-type entity_state() ::
    fistful_identity_thrift:'IdentityState'()
    | fistful_wallet_thrift:'WalletState'()
    | fistful_destination_thrift:'DestinationState'()
    | fistful_w2w_transfer_thrift:'W2WTransferState'()
    | fistful_wthd_thrift:'WithdrawalState'().

-export([gen_id/3]).
-export([gen_id/4]).
-export([make_ctx/1]).
-export([add_to_ctx/2]).
-export([add_to_ctx/3]).
-export([get_from_ctx/2]).
-export([get_idempotent_key/3]).
-export([issue_grant_token/3]).
-export([create_params_hash/1]).
-export([decode_resource/1]).
-export([tokenize_resource/1]).
-export([get_entity_owner/2]).

%% Pipeline

-spec get_idempotent_key(gen_type(), id(), id() | undefined) -> binary().
get_idempotent_key(Type, PartyID, ExternalID) ->
    bender_client:get_idempotent_key(?BENDER_DOMAIN, Type, PartyID, ExternalID).

-spec gen_id(gen_type(), params(), handler_context()) -> {ok, id()} | {error, {external_id_conflict, id()}}.
gen_id(Type, Params, Context) ->
    ExternalID = maps:get(?EXTERNAL_ID, Params, undefined),
    Hash = create_params_hash(Params),
    gen_id(Type, ExternalID, Hash, Context).

-spec gen_id(gen_type(), id() | undefined, hash(), handler_context()) ->
    {ok, id()} | {error, {external_id_conflict, id()}}.
gen_id(Type, ExternalID, Hash, Context) ->
    PartyID = wapi_handler_utils:get_owner(Context),
    IdempotentKey = bender_client:get_idempotent_key(?BENDER_DOMAIN, Type, PartyID, ExternalID),
    gen_id_by_type(Type, IdempotentKey, Hash, Context).

%@TODO: Bring back later
%gen_id_by_type(withdrawal = Type, IdempotentKey, Hash, Context) ->
%    gen_snowflake_id(Type, IdempotentKey, Hash, Context);
gen_id_by_type(Type, IdempotentKey, Hash, Context) ->
    gen_sequence_id(Type, IdempotentKey, Hash, Context).

%@TODO: Bring back later
%gen_snowflake_id(_Type, IdempotentKey, Hash, #{woody_context := WoodyCtx}) ->
%    bender_client:gen_snowflake(IdempotentKey, Hash, WoodyCtx).
gen_sequence_id(Type, IdempotentKey, Hash, #{woody_context := WoodyCtx}) ->
    BinType = atom_to_binary(Type, utf8),
    BenderCtx = #{
        <<"version">> => ?BENDER_SCHEMA_VER1,
        <<"params_hash">> => Hash
    },
    case bender_client:gen_sequence(IdempotentKey, BinType, WoodyCtx, BenderCtx) of
        {ok, ID} ->
            {ok, ID};
        {ok, ID, #{<<"version">> := ?BENDER_SCHEMA_VER1, <<"params_hash">> := Hash}} ->
            {ok, ID};
        {ok, ID, #{<<"version">> := ?BENDER_SCHEMA_VER1, <<"params_hash">> := _}} ->
            {error, {external_id_conflict, ID}}
    end.

-spec make_ctx(params()) -> context().
make_ctx(Params) ->
    #{
        ?CTX_NS => genlib_map:compact(#{
            <<"owner">> => maps:get(<<"partyID">>, Params),
            <<"metadata">> => maps:get(<<"metadata">>, Params, undefined)
        })
    }.

-spec add_to_ctx({md(), md() | undefined} | list() | map(), context()) -> context().
add_to_ctx({Key, Value}, Context) ->
    add_to_ctx(Key, Value, Context);
add_to_ctx(Map, #{?CTX_NS := Ctx} = Context) when is_map(Map) ->
    Context#{?CTX_NS => maps:merge(Ctx, Map)};
add_to_ctx(KVList, Context) when is_list(KVList) ->
    lists:foldl(
        fun({K, V}, Ctx) -> add_to_ctx(K, V, Ctx) end,
        Context,
        KVList
    ).

-spec add_to_ctx(md(), md() | undefined, context()) -> context().
add_to_ctx(_Key, undefined, Context) ->
    Context;
add_to_ctx(Key, Value, #{?CTX_NS := Ctx} = Context) ->
    Context#{?CTX_NS => Ctx#{Key => Value}}.

-spec get_from_ctx(md(), context()) -> md().
get_from_ctx(Key, #{?CTX_NS := Ctx}) ->
    maps:get(Key, Ctx, undefined);
get_from_ctx(Key, Ctx) ->
    LegacyNSs = genlib_app:env(wapi_lib, legacy_context_namespaces, []),
    genlib_list:foldl_while(
        fun(NS, Acc) ->
            case Ctx of
                #{NS := #{Key := Value}} ->
                    {halt, Value};
                _ ->
                    {cont, Acc}
            end
        end,
        undefined,
        LegacyNSs
    ).

-spec issue_grant_token(_, binary(), handler_context()) -> {ok, binary()} | {error, expired}.
issue_grant_token(TokenSpec, Expiration, Context) ->
    case get_expiration_deadline(Expiration) of
        {ok, Deadline} ->
            {ok, wapi_tokens_legacy:issue_access_token(wapi_handler_utils:get_owner(Context), TokenSpec, Deadline)};
        Error = {error, _} ->
            Error
    end.

get_expiration_deadline(Expiration) ->
    Deadline = genlib_rfc3339:parse(Expiration, second),
    case genlib_time:unow() - Deadline < 0 of
        true ->
            {ok, Deadline};
        false ->
            {error, expired}
    end.

-spec create_params_hash(term()) -> integer().
create_params_hash(Value) ->
    erlang:phash2(Value).

-spec decode_resource(binary()) ->
    {ok, wapi_crypto:resource()} | {error, unrecognized} | {error, lechiffre:decoding_error()}.
decode_resource(Token) ->
    case wapi_crypto:decrypt_resource_token(Token) of
        {ok, {Resource, Deadline}} ->
            case wapi_utils:deadline_is_reached(Deadline) of
                true ->
                    {error, expired};
                _ ->
                    {ok, Resource}
            end;
        unrecognized ->
            {error, unrecognized};
        {error, Error} ->
            {error, Error}
    end.

-spec tokenize_resource(wapi_crypto:resource() | term()) -> integer().
tokenize_resource({bank_card, BankCard}) ->
    Map = genlib_map:compact(#{
        token => BankCard#'fistful_base_BankCard'.token,
        bin => BankCard#'fistful_base_BankCard'.bin,
        masked_pan => BankCard#'fistful_base_BankCard'.masked_pan,
        cardholder_name => BankCard#'fistful_base_BankCard'.cardholder_name,
        %% ExpDate is optional in swag_wallets 'StoreBankCard'. But some adapters waiting exp_date.
        %% Add error, somethink like BankCardReject.exp_date_required
        exp_date =>
            case BankCard#'fistful_base_BankCard'.exp_date of
                undefined -> undefined;
                #'fistful_base_BankCardExpDate'{month = Month, year = Year} -> {Month, Year}
            end
    }),
    create_params_hash(Map);
tokenize_resource(Value) ->
    create_params_hash(Value).

-spec get_entity_owner(entity_type(), entity_state()) -> {ok, id()}.
get_entity_owner(Type, State) ->
    {ok, get_context_owner(get_context_from_state(Type, State))}.

get_context_from_state(identity, #identity_IdentityState{context = Context}) ->
    Context;
get_context_from_state(wallet, #wallet_WalletState{context = Context}) ->
    Context;
get_context_from_state(destination, #destination_DestinationState{context = Context}) ->
    Context;
get_context_from_state(w2w_transfer, #w2w_transfer_W2WTransferState{context = Context}) ->
    Context;
get_context_from_state(withdrawal, #wthd_WithdrawalState{context = Context}) ->
    Context.

get_context_owner(ContextThrift) ->
    Context = wapi_codec:unmarshal(context, ContextThrift),
    wapi_backend_utils:get_from_ctx(<<"owner">>, Context).
