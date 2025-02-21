-module(wapi_identity_backend).

-type handler_context() :: wapi_handler_utils:handler_context().
-type response_data() :: wapi_handler_utils:response_data().
-type params() :: map().
-type id() :: binary().
-type result(T, E) :: {ok, T} | {error, E}.
-type identity_state() :: fistful_identity_thrift:'IdentityState'().

-export_type([identity_state/0]).

-export([create/2]).
-export([get/2]).

-export([get_thrift_identity/2]).
-export([get_identity_withdrawal_methods/2]).

-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_identity_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").

%% Pipeline

-spec get(id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {identity, notfound}}.
get(IdentityID, HandlerContext) ->
    case get_thrift_identity(IdentityID, HandlerContext) of
        {ok, IdentityThrift} ->
            {ok, Owner} = wapi_backend_utils:get_entity_owner(identity, IdentityThrift),
            {ok, unmarshal_identity(IdentityThrift), Owner};
        {error, _} = Error ->
            Error
    end.

-spec create(params(), handler_context()) ->
    result(
        map(),
        {provider, notfound}
        | {external_id_conflict, id()}
        | inaccessible
        | _Unexpected
    ).
create(Params, HandlerContext) ->
    case wapi_backend_utils:gen_id(identity, Params, HandlerContext) of
        {ok, ID} ->
            case is_id_unknown(ID, Params, HandlerContext) of
                true ->
                    create_identity(ID, Params, HandlerContext);
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
        <<"provider">> := Provider
    },
    HandlerContext
) ->
    case get(ID, HandlerContext) of
        {error, {identity, notfound}} ->
            true;
        {ok,
            #{
                <<"id">> := ID,
                <<"name">> := Name,
                <<"provider">> := Provider
            },
            _Owner} ->
            true;
        {ok, _NonMatchingIdentity, _Owner} ->
            false
    end.

create_identity(ID, Params, HandlerContext) ->
    IdentityParams = marshal(identity_params, Params#{<<"id">> => ID}),
    Request = {fistful_identity, 'Create', {IdentityParams, marshal(context, create_context(Params))}},

    case service_call(Request, HandlerContext) of
        {ok, Identity} ->
            {ok, unmarshal_identity(Identity)};
        {exception, #fistful_PartyNotFound{}} ->
            {error, {party, notfound}};
        {exception, #fistful_ProviderNotFound{}} ->
            {error, {provider, notfound}};
        {exception, #fistful_PartyInaccessible{}} ->
            {error, inaccessible};
        {exception, Details} ->
            {error, Details}
    end.

-spec get_thrift_identity(id(), handler_context()) ->
    {ok, identity_state()}
    | {error, {identity, notfound}}.
get_thrift_identity(IdentityID, HandlerContext) ->
    Request = {fistful_identity, 'Get', {IdentityID, #'fistful_base_EventRange'{}}},
    case service_call(Request, HandlerContext) of
        {ok, IdentityThrift} ->
            {ok, IdentityThrift};
        {exception, #fistful_IdentityNotFound{}} ->
            {error, {identity, notfound}}
    end.

-spec get_identity_withdrawal_methods(id(), handler_context()) ->
    {ok, response_data()}
    | {error, {identity, notfound}}.
get_identity_withdrawal_methods(IdentityID, HandlerContext) ->
    Request = {fistful_identity, 'GetWithdrawalMethods', {IdentityID}},
    case service_call(Request, HandlerContext) of
        {ok, Methods} ->
            {ok, unmarshal_withdrawal_methods(Methods)};
        {exception, #fistful_IdentityNotFound{}} ->
            {error, {identity, notfound}}
    end.

%%
%% Internal
%%

create_context(Params) ->
    KV = {<<"name">>, maps:get(<<"name">>, Params, undefined)},
    wapi_backend_utils:add_to_ctx(KV, wapi_backend_utils:make_ctx(Params)).

service_call(Params, Ctx) ->
    wapi_handler_utils:service_call(Params, Ctx).

%% Marshaling

marshal(
    identity_params,
    #{
        <<"id">> := ID,
        <<"name">> := Name,
        <<"provider">> := Provider,
        <<"partyID">> := PartyID
    } = Params
) ->
    ExternalID = maps:get(<<"externalID">>, Params, undefined),
    #identity_IdentityParams{
        id = marshal(id, ID),
        name = marshal(string, Name),
        party = marshal(id, PartyID),
        provider = marshal(string, Provider),
        external_id = marshal(id, ExternalID)
    };
marshal(context, Ctx) ->
    wapi_codec:marshal(context, Ctx);
marshal(T, V) ->
    wapi_codec:marshal(T, V).

%%

unmarshal_withdrawal_methods(Methods) ->
    MethodMap = ordsets:fold(fun unmarshal_withdrawal_method/2, #{}, Methods),
    #{
        <<"methods">> => [
            #{
                <<"method">> => <<"WithdrawalMethodBankCard">>,
                <<"paymentSystems">> => maps:get(bank_card, MethodMap, [])
            },
            #{
                <<"method">> => <<"WithdrawalMethodDigitalWallet">>,
                <<"providers">> => maps:get(digital_wallet, MethodMap, [])
            },
            #{
                <<"method">> => <<"WithdrawalMethodGeneric">>,
                <<"providers">> => maps:get(generic, MethodMap, [])
            }
            %% TODO: Need to add method type for crypto currency TD-250
        ]
    }.

unmarshal_withdrawal_method({bank_card, #'fistful_BankCardWithdrawalMethod'{payment_system = PaymentSystem}}, Acc0) ->
    Methods = maps:get(bank_card, Acc0, []),
    #{id := ID} = unmarshal(payment_system, PaymentSystem),
    Acc0#{bank_card => [ID | Methods]};
unmarshal_withdrawal_method({digital_wallet, PaymentServiceRef}, Acc0) ->
    Methods = maps:get(digital_wallet, Acc0, []),
    #{id := ID} = unmarshal(payment_service, PaymentServiceRef),
    Acc0#{digital_wallet => [ID | Methods]};
unmarshal_withdrawal_method({generic, PaymentServiceRef}, Acc0) ->
    Methods = maps:get(generic, Acc0, []),
    #{id := ID} = unmarshal(payment_service, PaymentServiceRef),
    Acc0#{generic => [ID | Methods]};
unmarshal_withdrawal_method({crypto_currency, CryptoCurrencyRef}, Acc0) ->
    Methods = maps:get(crypto_currency, Acc0, []),
    #{id := ID} = unmarshal(crypto_currency, CryptoCurrencyRef),
    Acc0#{crypto_currency => [ID | Methods]}.

unmarshal_identity(#identity_IdentityState{
    id = IdentityID,
    name = Name,
    blocking = Blocking,
    provider_id = Provider,
    external_id = ExternalID,
    created_at = CreatedAt,
    context = Ctx
}) ->
    Context = unmarshal(context, Ctx),
    genlib_map:compact(#{
        <<"id">> => unmarshal(id, IdentityID),
        <<"name">> => unmarshal(string, Name),
        <<"createdAt">> => maybe_unmarshal(string, CreatedAt),
        <<"isBlocked">> => unmarshal_blocking(Blocking),
        <<"provider">> => unmarshal(id, Provider),
        <<"externalID">> => maybe_unmarshal(id, ExternalID),
        <<"metadata">> => wapi_backend_utils:get_from_ctx(<<"metadata">>, Context)
    }).

unmarshal_blocking(undefined) ->
    undefined;
unmarshal_blocking(unblocked) ->
    false;
unmarshal_blocking(blocked) ->
    true.

unmarshal(T, V) ->
    wapi_codec:unmarshal(T, V).

maybe_unmarshal(_, undefined) ->
    undefined;
maybe_unmarshal(T, V) ->
    unmarshal(T, V).
