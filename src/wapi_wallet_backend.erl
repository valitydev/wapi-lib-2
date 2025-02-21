-module(wapi_wallet_backend).

-type request_data() :: wapi_wallet_handler:request_data().
-type handler_context() :: wapi_handler_utils:handler_context().
-type response_data() :: wapi_handler_utils:response_data().
-type id() :: binary().
-type external_id() :: binary().

-export([create/2]).
-export([get/2]).
-export([get_by_external_id/2]).
-export([get_account/2]).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wallet_thrift.hrl").

%% Pipeline

-spec create(request_data(), handler_context()) -> {ok, response_data()} | {error, WalletError} when
    WalletError ::
        {identity, notfound}
        | {currency, notfound}
        | inaccessible
        | {external_id_conflict, id()}.
create(Params, HandlerContext) ->
    case wapi_backend_utils:gen_id(wallet, Params, HandlerContext) of
        {ok, ID} ->
            case is_id_unknown(ID, Params, HandlerContext) of
                true ->
                    Context = wapi_backend_utils:make_ctx(Params),
                    create(ID, Params, Context, HandlerContext);
                false ->
                    create(Params, HandlerContext)
            end;
        {error, {external_id_conflict, _}} = Error ->
            Error
    end.

is_id_unknown(
    ID,
    #{
        <<"name">> := Name,
        <<"identity">> := IdentityID,
        <<"currency">> := CurrencyID
    },
    HandlerContext
) ->
    case get(ID, HandlerContext) of
        {error, {wallet, notfound}} ->
            true;
        {ok,
            #{
                <<"id">> := ID,
                <<"name">> := Name,
                <<"identity">> := IdentityID,
                <<"currency">> := CurrencyID
            },
            _Owner} ->
            true;
        {ok, _NonMatchingIdentity, _Owner} ->
            false
    end.

create(WalletID, Params, Context, HandlerContext) ->
    WalletParams = marshal(wallet_params, Params#{<<"id">> => WalletID}),
    Request = {fistful_wallet, 'Create', {WalletParams, marshal(context, Context)}},
    case service_call(Request, HandlerContext) of
        {ok, Wallet} ->
            {ok, unmarshal(wallet, Wallet)};
        {exception, #fistful_IdentityNotFound{}} ->
            {error, {identity, notfound}};
        {exception, #fistful_CurrencyNotFound{}} ->
            {error, {currency, notfound}};
        {exception, #fistful_PartyInaccessible{}} ->
            {error, inaccessible};
        {exception, Details} ->
            {error, Details}
    end.

-spec get_by_external_id(external_id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {wallet, notfound}}
    | {error, {external_id, {unknown_external_id, external_id()}}}.
get_by_external_id(ExternalID, #{woody_context := WoodyContext} = HandlerContext) ->
    PartyID = wapi_handler_utils:get_owner(HandlerContext),
    IdempotentKey = wapi_backend_utils:get_idempotent_key(wallet, PartyID, ExternalID),
    case bender_client:get_internal_id(IdempotentKey, WoodyContext) of
        {ok, WalletID, _} ->
            get(WalletID, HandlerContext);
        {error, internal_id_not_found} ->
            {error, {external_id, {unknown_external_id, ExternalID}}}
    end.

-spec get(id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {wallet, notfound}}.
get(WalletID, HandlerContext) ->
    Request = {fistful_wallet, 'Get', {WalletID, #'fistful_base_EventRange'{}}},
    case service_call(Request, HandlerContext) of
        {ok, WalletThrift} ->
            {ok, Owner} = wapi_backend_utils:get_entity_owner(wallet, WalletThrift),
            {ok, unmarshal(wallet, WalletThrift), Owner};
        {exception, #fistful_WalletNotFound{}} ->
            {error, {wallet, notfound}}
    end.

-spec get_account(id(), handler_context()) ->
    {ok, response_data()}
    | {error, {wallet, notfound}}.
get_account(WalletID, HandlerContext) ->
    Request = {fistful_wallet, 'GetAccountBalance', {WalletID}},
    case service_call(Request, HandlerContext) of
        {ok, AccountBalanceThrift} ->
            {ok, unmarshal(wallet_account_balance, AccountBalanceThrift)};
        {exception, #fistful_WalletNotFound{}} ->
            {error, {wallet, notfound}}
    end.

%%
%% Internal
%%

service_call(Params, Ctx) ->
    wapi_handler_utils:service_call(Params, Ctx).

%% Marshaling

marshal(
    wallet_params,
    #{
        <<"id">> := ID,
        <<"name">> := Name,
        <<"identity">> := IdentityID,
        <<"currency">> := CurrencyID
    } = Params
) ->
    ExternalID = maps:get(<<"externalID">>, Params, undefined),
    #wallet_WalletParams{
        id = marshal(id, ID),
        name = marshal(string, Name),
        account_params = marshal(account_params, {IdentityID, CurrencyID}),
        external_id = marshal(id, ExternalID)
    };
marshal(account_params, {IdentityID, CurrencyID}) ->
    #account_AccountParams{
        identity_id = marshal(id, IdentityID),
        symbolic_code = marshal(string, CurrencyID)
    };
marshal(context, Ctx) ->
    wapi_codec:marshal(context, Ctx);
marshal(T, V) ->
    wapi_codec:marshal(T, V).

%%

unmarshal(wallet, #wallet_WalletState{
    id = WalletID,
    name = Name,
    blocking = Blocking,
    account = Account,
    external_id = ExternalID,
    created_at = CreatedAt,
    context = Ctx
}) ->
    #{
        identity := Identity,
        currency := Currency
    } = unmarshal(account, Account),
    Context = unmarshal(context, Ctx),
    genlib_map:compact(#{
        <<"id">> => unmarshal(id, WalletID),
        <<"name">> => unmarshal(string, Name),
        <<"isBlocked">> => unmarshal(blocking, Blocking),
        <<"identity">> => Identity,
        <<"currency">> => Currency,
        <<"createdAt">> => CreatedAt,
        <<"externalID">> => maybe_unmarshal(id, ExternalID),
        <<"metadata">> => wapi_backend_utils:get_from_ctx(<<"metadata">>, Context)
    });
unmarshal(blocking, unblocked) ->
    false;
unmarshal(blocking, blocked) ->
    true;
unmarshal(wallet_account_balance, #account_AccountBalance{
    current = OwnAmount,
    expected_min = AvailableAmount,
    currency = Currency
}) ->
    EncodedCurrency = unmarshal(currency_ref, Currency),
    #{
        <<"own">> => #{
            <<"amount">> => OwnAmount,
            <<"currency">> => EncodedCurrency
        },
        <<"available">> => #{
            <<"amount">> => AvailableAmount,
            <<"currency">> => EncodedCurrency
        }
    };
unmarshal(context, Ctx) ->
    wapi_codec:unmarshal(context, Ctx);
unmarshal(T, V) ->
    wapi_codec:unmarshal(T, V).

maybe_unmarshal(_, undefined) ->
    undefined;
maybe_unmarshal(T, V) ->
    unmarshal(T, V).
