-module(wapi_withdrawal_backend).

-define(EVENT(ID, Timestamp, Change), #wthd_Event{
    event_id = ID,
    occured_at = Timestamp,
    change = Change
}).

-define(STATUS_CHANGE(Status), {status_changed, #wthd_StatusChange{status = Status}}).

-type request_data() :: wapi_wallet_handler:request_data().
-type handler_context() :: wapi_handler_utils:handler_context().
-type response_data() :: wapi_handler_utils:response_data().
-type id() :: binary().
-type external_id() :: binary().

-type create_error() ::
    {destination, notfound | unauthorized | forbidden_withdrawal_method}
    | {wallet, notfound}
    | {external_id_conflict, id()}
    | {quote_invalid_party, _}
    | {quote_invalid_wallet, _}
    | {quote, {invalid_body, _}}
    | {quote, {invalid_destination, _}}
    | {forbidden_currency, _}
    | {forbidden_amount, _}
    | {invalid_amount, _}
    | {inconsistent_currency, _}
    | {quote, token_expired}
    | {identity_providers_mismatch, {id(), id()}}
    | {destination_resource, {bin_data, not_found}}.

-type create_quote_error() ::
    {destination, notfound | unauthorized | forbidden_withdrawal_method}
    | {wallet, notfound}
    | {forbidden_currency, _}
    | {forbidden_amount, _}
    | {invalid_amount, _}
    | {inconsistent_currency, _}
    | {identity_providers_mismatch, {id(), id()}}
    | {destination_resource, {bin_data, not_found}}.

-export([create/2]).
-export([get/2]).
-export([get_by_external_id/2]).
-export([create_quote/2]).
-export([get_events/2]).
-export([get_event/3]).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_status_thrift.hrl").

%% Pipeline

-import(wapi_pipeline, [do/1, unwrap/1, unwrap/2]).

-spec create(request_data(), handler_context()) -> {ok, response_data()} | {error, create_error()}.
create(Params0, HandlerContext) ->
    case check_withdrawal_params(Params0, HandlerContext) of
        {ok, Params1} ->
            Context = wapi_backend_utils:make_ctx(Params1),
            WithdrawalContext = marshal(context, Context),
            WithdrawalParams = marshal(withdrawal_params, Params1),
            create(WithdrawalParams, WithdrawalContext, HandlerContext);
        {error, _} = Error ->
            Error
    end.

create(Params, Context, HandlerContext) ->
    Request = {fistful_withdrawal, 'Create', {Params, Context}},
    case service_call(Request, HandlerContext) of
        {ok, Withdrawal} ->
            {ok, unmarshal(withdrawal, Withdrawal)};
        {exception, #fistful_WalletNotFound{}} ->
            {error, {wallet, notfound}};
        {exception, #fistful_DestinationNotFound{}} ->
            {error, {destination, notfound}};
        {exception, #fistful_DestinationUnauthorized{}} ->
            {error, {destination, unauthorized}};
        {exception, #fistful_ForbiddenOperationCurrency{currency = Currency}} ->
            {error, {forbidden_currency, unmarshal_currency_ref(Currency)}};
        {exception, #fistful_ForbiddenOperationAmount{amount = Amount}} ->
            {error, {forbidden_amount, unmarshal_body(Amount)}};
        {exception, #fistful_InvalidOperationAmount{amount = Amount}} ->
            {error, {invalid_amount, unmarshal_body(Amount)}};
        {exception, #wthd_InconsistentWithdrawalCurrency{
            withdrawal_currency = WithdrawalCurrency,
            destination_currency = DestinationCurrency,
            wallet_currency = WalletCurrency
        }} ->
            {error,
                {inconsistent_currency, {
                    unmarshal_currency_ref(WithdrawalCurrency),
                    unmarshal_currency_ref(DestinationCurrency),
                    unmarshal_currency_ref(WalletCurrency)
                }}};
        {exception, #wthd_IdentityProvidersMismatch{
            wallet_provider = WalletProvider,
            destination_provider = DestinationProvider
        }} ->
            {error, {identity_providers_mismatch, {WalletProvider, DestinationProvider}}};
        {exception, #wthd_NoDestinationResourceInfo{}} ->
            {error, {destination_resource, {bin_data, not_found}}};
        {exception, #fistful_WalletInaccessible{id = WalletID}} ->
            {error, {wallet, {inaccessible, WalletID}}};
        {exception, #fistful_ForbiddenWithdrawalMethod{}} ->
            {error, {destination, forbidden_withdrawal_method}}
    end.

-spec get(id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {withdrawal, notfound}}.
get(WithdrawalID, HandlerContext) ->
    Request = {fistful_withdrawal, 'Get', {WithdrawalID, #'fistful_base_EventRange'{}}},
    case service_call(Request, HandlerContext) of
        {ok, WithdrawalThrift} ->
            {ok, Owner} = wapi_backend_utils:get_entity_owner(withdrawal, WithdrawalThrift),
            {ok, unmarshal(withdrawal, WithdrawalThrift), Owner};
        {exception, #fistful_WithdrawalNotFound{}} ->
            {error, {withdrawal, notfound}}
    end.

-spec get_by_external_id(external_id(), handler_context()) ->
    {ok, response_data(), id()}
    | {error, {withdrawal, notfound}}
    | {error, {external_id, {unknown_external_id, external_id()}}}.
get_by_external_id(ExternalID, #{woody_context := WoodyContext} = HandlerContext) ->
    PartyID = wapi_handler_utils:get_owner(HandlerContext),
    IdempotentKey = wapi_backend_utils:get_idempotent_key(withdrawal, PartyID, ExternalID),
    case bender_client:get_internal_id(IdempotentKey, WoodyContext) of
        {ok, WithdrawalID, _CtxData} ->
            get(WithdrawalID, HandlerContext);
        {error, internal_id_not_found} ->
            {error, {external_id, {unknown_external_id, ExternalID}}}
    end.

-spec create_quote(request_data(), handler_context()) -> {ok, response_data()} | {error, create_quote_error()}.
create_quote(Params, HandlerContext) ->
    CreateQuoteParams = marshal(create_quote_params, Params),
    Request = {fistful_withdrawal, 'GetQuote', {CreateQuoteParams}},
    case service_call(Request, HandlerContext) of
        {ok, QuoteThrift} ->
            Token = create_quote_token(
                QuoteThrift,
                maps:get(<<"walletID">>, Params),
                maps:get(<<"destinationID">>, Params, undefined),
                maps:get(<<"partyID">>, Params)
            ),
            UnmarshaledQuote = unmarshal(quote, QuoteThrift),
            {ok, UnmarshaledQuote#{<<"quoteToken">> => Token}};
        {exception, #fistful_WalletNotFound{}} ->
            {error, {wallet, notfound}};
        {exception, #fistful_DestinationNotFound{}} ->
            {error, {destination, notfound}};
        {exception, #fistful_DestinationUnauthorized{}} ->
            {error, {destination, unauthorized}};
        {exception, #fistful_ForbiddenOperationCurrency{currency = Currency}} ->
            {error, {forbidden_currency, unmarshal_currency_ref(Currency)}};
        {exception, #fistful_ForbiddenOperationAmount{amount = Amount}} ->
            {error, {forbidden_amount, unmarshal_body(Amount)}};
        {exception, #fistful_InvalidOperationAmount{amount = Amount}} ->
            {error, {invalid_amount, unmarshal_body(Amount)}};
        {exception, #wthd_InconsistentWithdrawalCurrency{
            withdrawal_currency = WithdrawalCurrency,
            destination_currency = DestinationCurrency,
            wallet_currency = WalletCurrency
        }} ->
            {error,
                {inconsistent_currency, {
                    unmarshal_currency_ref(WithdrawalCurrency),
                    unmarshal_currency_ref(DestinationCurrency),
                    unmarshal_currency_ref(WalletCurrency)
                }}};
        {exception, #wthd_IdentityProvidersMismatch{
            wallet_provider = WalletProvider,
            destination_provider = DestinationProvider
        }} ->
            {error, {identity_providers_mismatch, {WalletProvider, DestinationProvider}}};
        {exception, #wthd_NoDestinationResourceInfo{}} ->
            {error, {destination_resource, {bin_data, not_found}}};
        {exception, #fistful_ForbiddenWithdrawalMethod{}} ->
            {error, {destination, forbidden_withdrawal_method}}
    end.

-spec get_events(request_data(), handler_context()) ->
    {ok, response_data()} | {error, {withdrawal, notfound}}.
get_events(#{'withdrawalID' := WithdrawalID, 'limit' := Limit} = Params, HandlerContext) ->
    Cursor = maps:get('eventCursor', Params, undefined),
    case get_events(WithdrawalID, {Cursor, Limit}, HandlerContext) of
        {ok, Events} ->
            {ok, Events};
        {exception, #fistful_WithdrawalNotFound{}} ->
            {error, {withdrawal, notfound}}
    end.

-spec get_event(id(), integer(), handler_context()) ->
    {ok, response_data()}
    | {error, {withdrawal, notfound}}
    | {error, {event, notfound}}.
get_event(WithdrawalID, EventId, HandlerContext) ->
    case get_events(WithdrawalID, {EventId - 1, 1}, HandlerContext) of
        {ok, [Event]} ->
            {ok, Event};
        {ok, []} ->
            {error, {event, notfound}};
        {exception, #fistful_WithdrawalNotFound{}} ->
            {error, {withdrawal, notfound}}
    end.

%%
%% Internal
%%

create_quote_token(Quote, WalletID, DestinationID, PartyID) ->
    Payload = wapi_withdrawal_quote:create_token_payload(Quote, WalletID, DestinationID, PartyID),
    {ok, Token} = issue_quote_token(PartyID, Payload),
    Token.

issue_quote_token(PartyID, Data) ->
    uac_authorizer_jwt:issue(wapi_utils:get_unique_id(), PartyID, Data, wapi_tokens_legacy:get_signee()).

service_call(Params, HandlerContext) ->
    wapi_handler_utils:service_call(Params, HandlerContext).

get_events(WithdrawalID, EventRange, HandlerContext) ->
    case get_events_(WithdrawalID, EventRange, HandlerContext) of
        {ok, Events0} ->
            Events1 = lists:filter(fun event_filter/1, Events0),
            {ok, unmarshal({list, event}, Events1)};
        {exception, _} = Exception ->
            Exception
    end.

get_events_(WithdrawalID, EventRange, HandlerContext) ->
    collect_events(WithdrawalID, EventRange, HandlerContext, []).

collect_events(WithdrawalID, {Cursor, Limit}, HandlerContext, AccEvents) ->
    Request = {fistful_withdrawal, 'GetEvents', {WithdrawalID, marshal_event_range(Cursor, Limit)}},
    case service_call(Request, HandlerContext) of
        {exception, _} = Exception ->
            Exception;
        {ok, []} ->
            {ok, AccEvents};
        {ok, Events} ->
            ?EVENT(NewCursor, _, _) = lists:last(Events),
            collect_events(WithdrawalID, {NewCursor, Limit - length(Events)}, HandlerContext, AccEvents ++ Events)
    end.

event_filter(?EVENT(_, _, ?STATUS_CHANGE(_))) ->
    true;
event_filter(_) ->
    false.

%% Validators
check_withdrawal_params(Params0, HandlerContext) ->
    do(fun() ->
        Params1 = unwrap(try_decode_quote_token(Params0)),
        Params2 = unwrap(maybe_check_quote_token(Params1, HandlerContext)),
        unwrap(generate_id(Params2, HandlerContext))
    end).

generate_id(Params, HandlerContext) ->
    case wapi_backend_utils:gen_id(withdrawal, Params, HandlerContext) of
        {ok, GenID} ->
            case is_id_unknown(GenID, Params, HandlerContext) of
                true ->
                    {ok, Params#{<<"id">> => GenID}};
                false ->
                    generate_id(Params, HandlerContext)
            end;
        {error, E} ->
            {error, E}
    end.

is_id_unknown(
    ID,
    #{
        <<"wallet">> := WalletID,
        <<"destination">> := DestinationID,
        <<"body">> := Body
    },
    HandlerContext
) ->
    case get(ID, HandlerContext) of
        {error, {withdrawal, notfound}} ->
            true;
        {ok,
            #{
                <<"id">> := ID,
                <<"wallet">> := WalletID,
                <<"destination">> := DestinationID,
                <<"body">> := Body
            },
            _Owner} ->
            true;
        {ok, _NonMatchingIdentity, _Owner} ->
            false
    end.

try_decode_quote_token(#{<<"quoteToken">> := QuoteToken} = Params) ->
    do(fun() ->
        {_, _, Data} = unwrap(uac_authorizer_jwt:verify(QuoteToken, #{})),
        {Quote, WalletID, DestinationID, PartyID} = unwrap(quote, wapi_withdrawal_quote:decode_token_payload(Data)),
        Params#{
            <<"quoteToken">> => #{
                quote => Quote,
                wallet_id => WalletID,
                destination_id => DestinationID,
                party_id => PartyID
            }
        }
    end);
try_decode_quote_token(Params) ->
    {ok, Params}.

maybe_check_quote_token(
    #{
        <<"quoteToken">> := #{
            quote := Quote,
            wallet_id := WalletID,
            destination_id := DestinationID,
            party_id := PartyID
        }
    } = Params,
    HandlerContext
) ->
    do(fun() ->
        unwrap(quote_invalid_party, valid(PartyID, wapi_handler_utils:get_owner(HandlerContext))),
        unwrap(quote_invalid_wallet, valid(WalletID, maps:get(<<"wallet">>, Params))),
        unwrap(check_quote_withdrawal(DestinationID, maps:get(<<"destination">>, Params))),
        unwrap(check_quote_body(Quote#wthd_Quote.cash_from, marshal_body(maps:get(<<"body">>, Params)))),
        Params#{<<"quote">> => Quote}
    end);
maybe_check_quote_token(Params, _Context) ->
    {ok, Params}.

valid(V, V) ->
    ok;
valid(_, V) ->
    {error, V}.

check_quote_body(CashFrom, CashFrom) ->
    ok;
check_quote_body(_, CashFrom) ->
    {error, {quote, {invalid_body, CashFrom}}}.

check_quote_withdrawal(undefined, _DestinationID) ->
    ok;
check_quote_withdrawal(DestinationID, DestinationID) ->
    ok;
check_quote_withdrawal(_, DestinationID) ->
    {error, {quote, {invalid_destination, DestinationID}}}.

%% Marshaling

marshal(
    withdrawal_params,
    #{
        <<"id">> := ID,
        <<"wallet">> := WalletID,
        <<"destination">> := DestinationID,
        <<"body">> := Body
    } = Params
) ->
    ExternalID = maps:get(<<"externalID">>, Params, undefined),
    Metadata = maps:get(<<"metadata">>, Params, undefined),
    Quote = maps:get(<<"quote">>, Params, undefined),
    #wthd_WithdrawalParams{
        id = marshal(id, ID),
        wallet_id = marshal(id, WalletID),
        destination_id = marshal(id, DestinationID),
        body = marshal_body(Body),
        quote = Quote,
        external_id = maybe_marshal(id, ExternalID),
        metadata = maybe_marshal(context, Metadata)
    };
marshal(
    create_quote_params,
    #{
        <<"walletID">> := WalletID,
        <<"currencyFrom">> := CurrencyFrom,
        <<"currencyTo">> := CurrencyTo,
        <<"cash">> := Body
    } = Params
) ->
    ExternalID = maps:get(<<"externalID">>, Params, undefined),
    DestinationID = maps:get(<<"destinationID">>, Params, undefined),
    #wthd_QuoteParams{
        wallet_id = marshal(id, WalletID),
        body = marshal_body(Body),
        currency_from = marshal_currency_ref(CurrencyFrom),
        currency_to = marshal_currency_ref(CurrencyTo),
        destination_id = maybe_marshal(id, DestinationID),
        external_id = maybe_marshal(id, ExternalID)
    };
marshal(context, Context) ->
    wapi_codec:marshal(context, Context);
marshal(T, V) ->
    wapi_codec:marshal(T, V).

maybe_marshal(_, undefined) ->
    undefined;
maybe_marshal(T, V) ->
    marshal(T, V).

marshal_event_range(Cursor, Limit) when
    (is_integer(Cursor) orelse Cursor =:= undefined) andalso
        (is_integer(Limit) orelse Limit =:= undefined)
->
    #'fistful_base_EventRange'{
        'after' = Cursor,
        'limit' = Limit
    }.

marshal_body(Body) ->
    #'fistful_base_Cash'{
        amount = genlib:to_int(maps:get(<<"amount">>, Body)),
        currency = marshal_currency_ref(maps:get(<<"currency">>, Body))
    }.

marshal_currency_ref(Currency) ->
    #'fistful_base_CurrencyRef'{
        symbolic_code = Currency
    }.

unmarshal({list, Type}, List) ->
    lists:map(fun(V) -> unmarshal(Type, V) end, List);
unmarshal(withdrawal, #wthd_WithdrawalState{
    id = ID,
    wallet_id = WalletID,
    destination_id = DestinationID,
    body = Body,
    external_id = ExternalID,
    status = Status,
    created_at = CreatedAt,
    metadata = Metadata,
    quote = Quote
}) ->
    UnmarshaledMetadata = maybe_unmarshal(context, Metadata),
    genlib_map:compact(
        maps:merge(
            #{
                <<"id">> => ID,
                <<"wallet">> => WalletID,
                <<"destination">> => DestinationID,
                <<"body">> => unmarshal_body(Body),
                <<"createdAt">> => CreatedAt,
                <<"externalID">> => ExternalID,
                <<"metadata">> => UnmarshaledMetadata,
                <<"quote">> => maybe_unmarshal(quote_state, Quote)
            },
            unmarshal_status(Status)
        )
    );
unmarshal(quote, #wthd_Quote{
    cash_from = CashFrom,
    cash_to = CashTo,
    created_at = CreatedAt,
    expires_on = ExpiresOn
}) ->
    #{
        <<"cashFrom">> => unmarshal_body(CashFrom),
        <<"cashTo">> => unmarshal_body(CashTo),
        <<"createdAt">> => CreatedAt,
        <<"expiresOn">> => ExpiresOn
    };
unmarshal(quote_state, #wthd_QuoteState{
    cash_from = CashFrom,
    cash_to = CashTo,
    created_at = CreatedAt,
    expires_on = ExpiresOn
}) ->
    #{
        <<"cashFrom">> => unmarshal_body(CashFrom),
        <<"cashTo">> => unmarshal_body(CashTo),
        <<"createdAt">> => CreatedAt,
        <<"expiresOn">> => ExpiresOn
    };
unmarshal(event, ?EVENT(EventId, OccuredAt, ?STATUS_CHANGE(Status))) ->
    genlib_map:compact(#{
        <<"eventID">> => EventId,
        <<"occuredAt">> => OccuredAt,
        <<"changes">> => [
            maps:merge(
                #{<<"type">> => <<"WithdrawalStatusChanged">>},
                unmarshal_status(Status)
            )
        ]
    });
unmarshal(T, V) ->
    wapi_codec:unmarshal(T, V).

maybe_unmarshal(_, undefined) ->
    undefined;
maybe_unmarshal(T, V) ->
    unmarshal(T, V).

unmarshal_body(#'fistful_base_Cash'{
    amount = Amount,
    currency = Currency
}) ->
    #{
        <<"amount">> => Amount,
        <<"currency">> => unmarshal_currency_ref(Currency)
    }.

unmarshal_currency_ref(#'fistful_base_CurrencyRef'{
    symbolic_code = Currency
}) ->
    Currency.

unmarshal_status({failed, #wthd_status_Failed{failure = BaseFailure}}) ->
    wapi_codec:convert(withdrawal_status, {failed, BaseFailure});
unmarshal_status(Status) ->
    wapi_codec:convert(withdrawal_status, Status).
