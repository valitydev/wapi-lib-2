-module(wapi_destination_backend).

-type request_data() :: wapi_wallet_handler:request_data().
-type handler_context() :: wapi_handler_utils:handler_context().
-type response_data() :: wapi_handler_utils:response_data().
-type id() :: binary().
-type external_id() :: binary().

-export([create/2]).
-export([get/2]).
-export([get_by_external_id/2]).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").

%% Pipeline

-import(wapi_pipeline, [do/1, unwrap/1]).

-spec create(request_data(), handler_context()) -> {ok, response_data()} | {error, DestinationError} when
    DestinationError ::
        {invalid_resource_token, binary()}
        | {invalid_generic_resource, {binary(), unknown_resource}}
        | {identity, notfound}
        | {currency, notfound}
        | inaccessible
        | forbidden_withdrawal_method
        | {external_id_conflict, {id(), external_id()}}.
create(Params, HandlerContext) ->
    do(fun() ->
        ResourceIn = maps:get(<<"resource">>, Params),
        Resource = secure_resource(ResourceIn, HandlerContext),
        ResourceThrift = unwrap(construct_resource(Resource, HandlerContext)),
        ID = unwrap(generate_id(Params, ResourceThrift, HandlerContext)),
        unwrap(create_request(ID, Params, ResourceThrift, HandlerContext))
    end).

generate_id(Params, ResourceThrift, HandlerContext) ->
    Resource = maps:get(<<"resource">>, Params),
    % replacing token with an tokenizedResource is need for naive idempotent algo.
    NewParams = Params#{
        <<"resource">> => Resource#{
            <<"token">> => undefined,
            <<"tokenizedResource">> => tokenize_resource(ResourceThrift)
        }
    },
    case wapi_backend_utils:gen_id(destination, NewParams, HandlerContext) of
        {ok, ID} ->
            case is_id_unknown(ID, Params, HandlerContext) of
                true ->
                    {ok, ID};
                false ->
                    generate_id(Params, ResourceThrift, HandlerContext)
            end;
        {error, {external_id_conflict, ID}} ->
            % Delete after deploy
            ExternalID = maps:get(<<"externalID">>, Params, undefined),
            logger:warning("external_id_conflict: ~p. try old hashing", [{ID, ExternalID}]),
            generate_id_legacy(Params, HandlerContext)
    end.

generate_id_legacy(Params, HandlerContext) ->
    case wapi_backend_utils:gen_id(destination, Params, HandlerContext) of
        {ok, ID} ->
            case is_id_unknown(ID, Params, HandlerContext) of
                true ->
                    {ok, ID};
                false ->
                    generate_id_legacy(Params, HandlerContext)
            end;
        {error, {external_id_conflict, ID}} ->
            ExternalID = maps:get(<<"externalID">>, Params, undefined),
            {error, {external_id_conflict, {ID, ExternalID}}}
    end.

is_id_unknown(
    ID,
    #{
        <<"identity">> := IdentityID,
        <<"currency">> := CurrencyID,
        <<"name">> := Name
    },
    HandlerContext
) ->
    case get(ID, HandlerContext) of
        {error, {destination, notfound}} ->
            true;
        {ok,
            #{
                <<"id">> := ID,
                <<"identity">> := IdentityID,
                <<"currency">> := CurrencyID,
                <<"name">> := Name
            },
            _Owner} ->
            true;
        {ok, _NonMatchingDestination, _Owner} ->
            false
    end.

create_request(ID, Params, ResourceThrift, HandlerContext) ->
    % mixing the attributes needed for marshaling
    MarshaledParams = marshal(destination_params, Params#{
        <<"id">> => ID,
        <<"resourceThrift">> => ResourceThrift
    }),
    MarshaledContext = marshal(context, wapi_backend_utils:make_ctx(Params)),
    Request = {fistful_destination, 'Create', {MarshaledParams, MarshaledContext}},
    case service_call(Request, HandlerContext) of
        {ok, Destination} ->
            {ok, unmarshal(destination, Destination)};
        {exception, #fistful_IdentityNotFound{}} ->
            {error, {identity, notfound}};
        {exception, #fistful_CurrencyNotFound{}} ->
            {error, {currency, notfound}};
        {exception, #fistful_PartyInaccessible{}} ->
            {error, inaccessible};
        {exception, #fistful_ForbiddenWithdrawalMethod{}} ->
            {error, forbidden_withdrawal_method};
        {exception, Details} ->
            {error, Details}
    end.

-spec get(id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {destination, notfound}}.
get(DestinationID, HandlerContext) ->
    Request = {fistful_destination, 'Get', {DestinationID, #'fistful_base_EventRange'{}}},
    case service_call(Request, HandlerContext) of
        {ok, DestinationThrift} ->
            {ok, Owner} = wapi_backend_utils:get_entity_owner(destination, DestinationThrift),
            {ok, unmarshal(destination, DestinationThrift), Owner};
        {exception, #fistful_DestinationNotFound{}} ->
            {error, {destination, notfound}}
    end.

-spec get_by_external_id(external_id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {destination, notfound}}
    | {error, {external_id, {unknown_external_id, external_id()}}}.
get_by_external_id(ExternalID, #{woody_context := WoodyContext} = HandlerContext) ->
    PartyID = wapi_handler_utils:get_owner(HandlerContext),
    IdempotentKey = wapi_backend_utils:get_idempotent_key(destination, PartyID, ExternalID),
    case bender_client:get_internal_id(IdempotentKey, WoodyContext) of
        {ok, DestinationID, _CtxData} ->
            get(DestinationID, HandlerContext);
        {error, internal_id_not_found} ->
            {error, {external_id, {unknown_external_id, ExternalID}}}
    end.

%%
%% Internal
%%

secure_resource(
    #{<<"type">> := <<"DigitalWalletDestinationResource">>, <<"token">> := Token} = Resource,
    #{woody_context := WoodyContext}
) ->
    TokenID = wapi_token_storage:put(Token, WoodyContext),
    Resource#{<<"token">> => TokenID};
secure_resource(Resource, _HandlerContext) ->
    Resource.

construct_resource(
    #{
        <<"type">> := <<"BankCardDestinationResource">> = Type,
        <<"token">> := Token
    },
    _Context
) ->
    case wapi_backend_utils:decode_resource(Token) of
        {ok, Resource} ->
            {bank_card, BankCard} = Resource,
            {ok, {bank_card, #'fistful_base_ResourceBankCard'{bank_card = BankCard}}};
        {error, Error} ->
            _ = logger:warning("BankCardDestinationResource token decryption failed: ~p", [Error]),
            {error, {invalid_resource_token, Type}}
    end;
construct_resource(
    #{
        <<"type">> := <<"CryptoWalletDestinationResource">>,
        <<"id">> := CryptoWalletID,
        <<"currency">> := Currency
    },
    _Context
) ->
    CostructedResource =
        {crypto_wallet, #{
            crypto_wallet => #{
                id => CryptoWalletID,
                currency => #{id => marshal(string, Currency)}
            }
        }},
    {ok, wapi_codec:marshal(resource, CostructedResource)};
construct_resource(
    #{
        <<"type">> := <<"DigitalWalletDestinationResource">>,
        <<"id">> := DigitalWalletID,
        <<"provider">> := Provider
    } = Resource,
    _Context
) ->
    ConstructedResource =
        {digital_wallet, #{
            digital_wallet => #{
                id => marshal(string, DigitalWalletID),
                payment_service => #{id => marshal(string, Provider)},
                token => maybe_marshal(string, maps:get(<<"token">>, Resource, undefined)),
                account_name => maybe_marshal(string, maps:get(<<"accountName">>, Resource, undefined)),
                account_identity_number => maybe_marshal(
                    string,
                    maps:get(<<"accountIdentityNumber">>, Resource, undefined)
                )
            }
        }},
    {ok, wapi_codec:marshal(resource, ConstructedResource)};
construct_resource(
    #{<<"type">> := GenericResourceType} = Resource,
    Context
) ->
    case prepare_generic_resource_data(GenericResourceType, Resource, Context) of
        {ok, Data} ->
            ConstructedResource =
                {generic, #{
                    generic => #{
                        payment_service => #{id => marshal(string, GenericResourceType)},
                        data => Data
                    }
                }},
            {ok, wapi_codec:marshal(resource, ConstructedResource)};
        {error, Error} ->
            {error, {invalid_generic_resource, {GenericResourceType, Error}}}
    end.

tokenize_resource({bank_card, #'fistful_base_ResourceBankCard'{bank_card = BankCard}}) ->
    wapi_backend_utils:tokenize_resource({bank_card, BankCard});
tokenize_resource({digital_wallet, Resource}) ->
    % NOTE
    % Deliberately excluding `token` from hashing because at this point it contains random string
    % and would break conflict detection otherwise.
    DigitalWallet = Resource#'fistful_base_ResourceDigitalWallet'.digital_wallet,
    wapi_backend_utils:tokenize_resource(
        {digital_wallet, Resource#'fistful_base_ResourceDigitalWallet'{
            digital_wallet = DigitalWallet#'fistful_base_DigitalWallet'{token = undefined}
        }}
    );
tokenize_resource(Value) ->
    wapi_backend_utils:tokenize_resource(Value).

prepare_generic_resource_data(ResourceType, Resource, #{swag_server_get_schema_fun := Get}) ->
    Schema = Get(),
    Definitions = maps:get(<<"definitions">>, Schema),
    ResourceSchema = maps:get(ResourceType, Definitions),
    case maps:get(<<"x-vality-genericMethod">>, ResourceSchema, undefined) of
        GenericMethodSchema when GenericMethodSchema =/= undefined ->
            SchemaID =
                case maps:get(<<"schema">>, GenericMethodSchema, #{}) of
                    #{<<"id">> := ID} ->
                        <<"application/schema-instance+json; schema=", ID/binary>>;
                    _Empty ->
                        <<"application/json">>
                end,
            {ok, #{type => SchemaID, data => jsx:encode(Resource)}};
        undefined ->
            {error, unknown_resource}
    end.

service_call(Params, Context) ->
    wapi_handler_utils:service_call(Params, Context).

%% Marshaling

marshal(
    destination_params,
    #{
        <<"id">> := ID,
        <<"identity">> := IdentityID,
        <<"currency">> := CurrencyID,
        <<"name">> := Name,
        <<"resourceThrift">> := Resource
    } = Params
) ->
    ExternalID = maps:get(<<"externalID">>, Params, undefined),
    AuthData = maps:get(<<"additionalAuthData">>, Params, undefined),
    #destination_DestinationParams{
        id = marshal(id, ID),
        identity = marshal(id, IdentityID),
        name = marshal(string, Name),
        currency = marshal(string, CurrencyID),
        external_id = maybe_marshal(id, ExternalID),
        resource = Resource,
        auth_data = maybe_marshal(auth_data, AuthData)
    };
marshal(context, Context) ->
    wapi_codec:marshal(context, Context);
marshal(auth_data, #{
    <<"type">> := <<"SenderReceiverDestinationAuthData">>,
    <<"senderToken">> := SenderToken,
    <<"receiverToken">> := ReceiverToken
}) ->
    {sender_receiver, #destination_SenderReceiverAuthData{
        sender = SenderToken,
        receiver = ReceiverToken
    }};
marshal(T, V) ->
    wapi_codec:marshal(T, V).

maybe_marshal(_, undefined) ->
    undefined;
maybe_marshal(T, V) ->
    marshal(T, V).

unmarshal(destination, #destination_DestinationState{
    id = DestinationID,
    name = Name,
    account = Account,
    external_id = ExternalID,
    created_at = CreatedAt,
    resource = Resource,
    status = Status,
    blocking = Blocking,
    context = Context
}) ->
    #{
        identity := Identity,
        currency := Currency
    } = unmarshal(account, Account),
    UnmarshaledContext = unmarshal(context, Context),
    genlib_map:compact(#{
        <<"id">> => unmarshal(id, DestinationID),
        <<"name">> => unmarshal(string, Name),
        <<"status">> => unmarshal(status, Status),
        <<"isBlocked">> => maybe_unmarshal(blocking, Blocking),
        <<"identity">> => Identity,
        <<"currency">> => Currency,
        <<"createdAt">> => CreatedAt,
        <<"resource">> => unmarshal(resource, Resource),
        <<"externalID">> => maybe_unmarshal(id, ExternalID),
        <<"metadata">> => wapi_backend_utils:get_from_ctx(<<"metadata">>, UnmarshaledContext)
    });
unmarshal(blocking, unblocked) ->
    false;
unmarshal(blocking, blocked) ->
    true;
unmarshal(status, {authorized, #destination_Authorized{}}) ->
    <<"Authorized">>;
unmarshal(status, {unauthorized, #destination_Unauthorized{}}) ->
    <<"Unauthorized">>;
unmarshal(
    resource,
    {bank_card, #'fistful_base_ResourceBankCard'{
        bank_card = #'fistful_base_BankCard'{
            token = Token,
            bin = Bin,
            masked_pan = MaskedPan
        }
    }}
) ->
    genlib_map:compact(#{
        <<"type">> => <<"BankCardDestinationResource">>,
        <<"token">> => unmarshal(string, Token),
        <<"bin">> => unmarshal(string, Bin),
        <<"lastDigits">> => wapi_utils:get_last_pan_digits(MaskedPan)
    });
unmarshal(
    resource,
    {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
        crypto_wallet = #'fistful_base_CryptoWallet'{
            id = CryptoWalletID,
            currency = #'fistful_base_CryptoCurrencyRef'{id = Currency},
            tag = Tag
        }
    }}
) ->
    genlib_map:compact(#{
        <<"type">> => <<"CryptoWalletDestinationResource">>,
        <<"id">> => unmarshal(string, CryptoWalletID),
        <<"currency">> => unmarshal(string, Currency),
        <<"tag">> => maybe_unmarshal(string, Tag)
    });
unmarshal(
    resource,
    {digital_wallet, #'fistful_base_ResourceDigitalWallet'{
        digital_wallet = #'fistful_base_DigitalWallet'{
            id = DigitalWalletID,
            payment_service = #'fistful_base_PaymentServiceRef'{id = Provider},
            account_name = AccountName,
            account_identity_number = AccountIdentityNumber
        }
    }}
) ->
    genlib_map:compact(#{
        <<"type">> => <<"DigitalWalletDestinationResource">>,
        <<"id">> => unmarshal(string, DigitalWalletID),
        <<"provider">> => unmarshal(string, Provider),
        <<"accountName">> => maybe_unmarshal(string, AccountName),
        <<"accountIdentityNumber">> => maybe_unmarshal(string, AccountIdentityNumber)
    });
unmarshal(
    resource,
    {generic, #'fistful_base_ResourceGeneric'{
        generic = #'fistful_base_ResourceGenericData'{
            provider = #'fistful_base_PaymentServiceRef'{id = Provider},
            data = #'fistful_base_Content'{data = Data}
        }
    }}
) ->
    Resource = jsx:decode(Data),
    Resource#{<<"type">> => Provider};
unmarshal(context, Context) ->
    wapi_codec:unmarshal(context, Context);
unmarshal(T, V) ->
    wapi_codec:unmarshal(T, V).

maybe_unmarshal(_, undefined) ->
    undefined;
maybe_unmarshal(T, V) ->
    unmarshal(T, V).
