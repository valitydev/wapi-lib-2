-module(wapi_codec).

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").

%% thrift record to internal map
-export([unmarshal/2]).
-export([unmarshal/3]).

%% internal map to thrift record
-export([marshal/2]).
-export([marshal/3]).

%% internal map to REST map
-export([convert/2]).

%% Types

-type type_name() :: atom() | {list, atom()} | {set, atom()}.
-type codec() :: module().

-type encoded_value() :: encoded_value(any()).
-type encoded_value(T) :: T.

-type decoded_value() :: decoded_value(any()).
-type decoded_value(T) :: T.

-export_type([codec/0]).
-export_type([type_name/0]).
-export_type([encoded_value/0]).
-export_type([encoded_value/1]).
-export_type([decoded_value/0]).
-export_type([decoded_value/1]).

%% Callbacks

-callback unmarshal(type_name(), encoded_value()) -> decoded_value().
-callback marshal(type_name(), decoded_value()) -> encoded_value().

%% API

-spec unmarshal(codec(), type_name(), encoded_value()) -> decoded_value().
unmarshal(Codec, Type, Value) ->
    Codec:unmarshal(Type, Value).

-spec marshal(codec(), type_name(), decoded_value()) -> encoded_value().
marshal(Codec, Type, Value) ->
    Codec:marshal(Type, Value).

%% Generic codec

-spec marshal(type_name(), decoded_value()) -> encoded_value().
marshal({list, T}, V) ->
    [marshal(T, E) || E <- V];
marshal({set, T}, V) ->
    ordsets:from_list([marshal(T, E) || E <- ordsets:to_list(V)]);
marshal(id, V) ->
    marshal(string, V);
marshal(event_id, V) ->
    marshal(integer, V);
marshal(provider_id, V) ->
    marshal(integer, V);
marshal(terminal_id, V) ->
    marshal(integer, V);
marshal(blocking, blocked) ->
    blocked;
marshal(blocking, unblocked) ->
    unblocked;
marshal(account_change, {created, Account}) ->
    {created, marshal(account, Account)};
marshal(account, #{
    id := ID,
    identity := IdentityID,
    currency := CurrencyID,
    accounter_account_id := AAID
}) ->
    #'account_Account'{
        id = marshal(id, ID),
        identity = marshal(id, IdentityID),
        currency = marshal(currency_ref, CurrencyID),
        accounter_account_id = marshal(event_id, AAID)
    };
marshal(resource, {bank_card, #{bank_card := BankCard} = ResourceBankCard}) ->
    {bank_card, #'fistful_base_ResourceBankCard'{
        bank_card = marshal(bank_card, BankCard),
        auth_data = maybe_marshal(bank_card_auth_data, maps:get(auth_data, ResourceBankCard, undefined))
    }};
marshal(resource, {crypto_wallet, #{crypto_wallet := CryptoWallet}}) ->
    {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
        crypto_wallet = marshal(crypto_wallet, CryptoWallet)
    }};
marshal(resource, {digital_wallet, #{digital_wallet := DigitalWallet}}) ->
    {digital_wallet, #'fistful_base_ResourceDigitalWallet'{
        digital_wallet = marshal(digital_wallet, DigitalWallet)
    }};
marshal(resource, {generic, #{generic := GenericResource}}) ->
    {generic, #'fistful_base_ResourceGeneric'{
        generic = marshal(generic_resource, GenericResource)
    }};
marshal(resource_descriptor, {bank_card, BinDataID}) ->
    {bank_card, #'fistful_base_ResourceDescriptorBankCard'{
        bin_data_id = marshal(msgpack, BinDataID)
    }};
marshal(bank_card, #{token := Token} = BankCard) ->
    Bin = maps:get(bin, BankCard, undefined),
    PaymentSystem = maps:get(payment_system, BankCard, undefined),
    MaskedPan = maps:get(masked_pan, BankCard, undefined),
    BankName = maps:get(bank_name, BankCard, undefined),
    IssuerCountry = maps:get(issuer_country, BankCard, undefined),
    CardType = maps:get(card_type, BankCard, undefined),
    ExpDate = maps:get(exp_date, BankCard, undefined),
    CardholderName = maps:get(cardholder_name, BankCard, undefined),
    BinDataID = maps:get(bin_data_id, BankCard, undefined),
    #'fistful_base_BankCard'{
        token = marshal(string, Token),
        bin = marshal(string, Bin),
        masked_pan = marshal(string, MaskedPan),
        bank_name = marshal(string, BankName),
        payment_system = maybe_marshal(payment_system, PaymentSystem),
        issuer_country = maybe_marshal(issuer_country, IssuerCountry),
        card_type = maybe_marshal(card_type, CardType),
        exp_date = maybe_marshal(exp_date, ExpDate),
        cardholder_name = maybe_marshal(string, CardholderName),
        bin_data_id = maybe_marshal(msgpack, BinDataID)
    };
marshal(bank_card_auth_data, {session, #{session_id := ID}}) ->
    {session_data, #'fistful_base_SessionAuthData'{
        id = marshal(string, ID)
    }};
marshal(crypto_wallet, #{id := ID, currency := Currency} = CryptoWallet) ->
    #'fistful_base_CryptoWallet'{
        id = marshal(string, ID),
        currency = marshal(crypto_currency, Currency),
        tag = maybe_marshal(string, maps:get(tag, CryptoWallet, undefined))
    };
marshal(digital_wallet, #{id := ID, payment_service := PaymentService} = Wallet) ->
    #'fistful_base_DigitalWallet'{
        id = marshal(string, ID),
        token = maybe_marshal(string, maps:get(token, Wallet, undefined)),
        payment_service = marshal(payment_service, PaymentService),
        account_name = maps:get(account_name, Wallet, undefined),
        account_identity_number = maps:get(account_identity_number, Wallet, undefined)
    };
marshal(generic_resource, #{payment_service := PaymentService} = Resource) ->
    Data = maybe_marshal(content, maps:get(data, Resource, undefined)),
    #'fistful_base_ResourceGenericData'{
        provider = marshal(payment_service, PaymentService),
        data = Data
    };
marshal(content, #{type := Type, data := Data}) ->
    #'fistful_base_Content'{
        type = marshal(string, Type),
        data = Data
    };
marshal(exp_date, {Month, Year}) ->
    #'fistful_base_BankCardExpDate'{
        month = marshal(integer, Month),
        year = marshal(integer, Year)
    };
marshal(crypto_currency, #{id := Ref}) when is_binary(Ref) ->
    #'fistful_base_CryptoCurrencyRef'{
        id = Ref
    };
marshal(payment_system, #{id := Ref}) when is_binary(Ref) ->
    #'fistful_base_PaymentSystemRef'{
        id = Ref
    };
marshal(payment_service, #{id := Ref}) when is_binary(Ref) ->
    #'fistful_base_PaymentServiceRef'{
        id = Ref
    };
marshal(issuer_country, V) when is_atom(V) ->
    V;
marshal(card_type, V) when is_atom(V) ->
    V;
marshal(cash, {Amount, CurrencyRef}) ->
    #'fistful_base_Cash'{
        amount = marshal(amount, Amount),
        currency = marshal(currency_ref, CurrencyRef)
    };
marshal(currency_ref, CurrencyID) when is_binary(CurrencyID) ->
    #'fistful_base_CurrencyRef'{
        symbolic_code = CurrencyID
    };
marshal(amount, V) ->
    marshal(integer, V);
marshal(event_range, {After, Limit}) ->
    #'fistful_base_EventRange'{
        'after' = maybe_marshal(integer, After),
        limit = maybe_marshal(integer, Limit)
    };
marshal(failure, Failure) ->
    #'fistful_base_Failure'{
        code = marshal(string, wapi_failure:code(Failure)),
        reason = maybe_marshal(string, wapi_failure:reason(Failure)),
        sub = maybe_marshal(sub_failure, wapi_failure:sub_failure(Failure))
    };
marshal(sub_failure, Failure) ->
    #'fistful_base_SubFailure'{
        code = marshal(string, wapi_failure:code(Failure)),
        sub = maybe_marshal(sub_failure, wapi_failure:sub_failure(Failure))
    };
marshal(domain_revision, V) when is_integer(V) ->
    V;
marshal(party_revision, V) when is_integer(V) ->
    V;
marshal(string, V) when is_binary(V) ->
    V;
marshal(integer, V) when is_integer(V) ->
    V;
marshal(bool, V) when is_boolean(V) ->
    V;
marshal(context, Ctx) when is_map(Ctx) ->
    maps:map(fun(_NS, V) -> marshal(msgpack, V) end, Ctx);
marshal(msgpack, V) ->
    wapi_msgpack_codec:marshal(msgpack, V);
% Catch this up in thrift validation
marshal(_, Other) ->
    Other.

-spec unmarshal(type_name(), encoded_value()) -> decoded_value().
unmarshal({list, T}, V) ->
    [unmarshal(T, E) || E <- V];
unmarshal({set, T}, V) ->
    ordsets:from_list([unmarshal(T, E) || E <- ordsets:to_list(V)]);
unmarshal(id, V) ->
    unmarshal(string, V);
unmarshal(event_id, V) ->
    unmarshal(integer, V);
unmarshal(provider_id, V) ->
    unmarshal(integer, V);
unmarshal(terminal_id, V) ->
    unmarshal(integer, V);
unmarshal(blocking, blocked) ->
    blocked;
unmarshal(blocking, unblocked) ->
    unblocked;
unmarshal(account_change, {created, Account}) ->
    {created, unmarshal(account, Account)};
unmarshal(account, #'account_Account'{
    id = ID,
    identity = IdentityID,
    currency = CurrencyRef,
    accounter_account_id = AAID
}) ->
    #{
        id => unmarshal(id, ID),
        identity => unmarshal(id, IdentityID),
        currency => unmarshal(currency_ref, CurrencyRef),
        accounter_account_id => unmarshal(accounter_account_id, AAID)
    };
unmarshal(accounter_account_id, V) ->
    unmarshal(integer, V);
unmarshal(
    resource,
    {bank_card, #'fistful_base_ResourceBankCard'{
        bank_card = BankCard,
        auth_data = AuthData
    }}
) ->
    {bank_card,
        genlib_map:compact(#{
            bank_card => unmarshal(bank_card, BankCard),
            auth_data => maybe_unmarshal(bank_card_auth_data, AuthData)
        })};
unmarshal(resource, {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{crypto_wallet = CryptoWallet}}) ->
    {crypto_wallet, #{
        crypto_wallet => unmarshal(crypto_wallet, CryptoWallet)
    }};
unmarshal(resource, {digital_wallet, #'fistful_base_ResourceDigitalWallet'{digital_wallet = DigitalWallet}}) ->
    {digital_wallet, #{
        digital_wallet => unmarshal(digital_wallet, DigitalWallet)
    }};
unmarshal(resource, {generic, #'fistful_base_ResourceGeneric'{generic = GenericResource}}) ->
    {generic, #{
        generic => unmarshal(generic_resource, GenericResource)
    }};
unmarshal(resource_descriptor, {bank_card, BankCard}) ->
    {bank_card, unmarshal(msgpack, BankCard#'fistful_base_ResourceDescriptorBankCard'.bin_data_id)};
unmarshal(bank_card_auth_data, {session_data, #'fistful_base_SessionAuthData'{id = ID}}) ->
    {session, #{
        session_id => unmarshal(string, ID)
    }};
unmarshal(bank_card, #'fistful_base_BankCard'{
    token = Token,
    bin = Bin,
    masked_pan = MaskedPan,
    bank_name = BankName,
    payment_system = PaymentSystem,
    issuer_country = IssuerCountry,
    card_type = CardType,
    bin_data_id = BinDataID,
    exp_date = ExpDate,
    cardholder_name = CardholderName
}) ->
    genlib_map:compact(#{
        token => unmarshal(string, Token),
        payment_system => maybe_unmarshal(payment_system, PaymentSystem),
        bin => maybe_unmarshal(string, Bin),
        masked_pan => maybe_unmarshal(string, MaskedPan),
        bank_name => maybe_unmarshal(string, BankName),
        issuer_country => maybe_unmarshal(issuer_country, IssuerCountry),
        card_type => maybe_unmarshal(card_type, CardType),
        exp_date => maybe_unmarshal(exp_date, ExpDate),
        cardholder_name => maybe_unmarshal(string, CardholderName),
        bin_data_id => maybe_unmarshal(msgpack, BinDataID)
    });
unmarshal(exp_date, #'fistful_base_BankCardExpDate'{
    month = Month,
    year = Year
}) ->
    {unmarshal(integer, Month), unmarshal(integer, Year)};
unmarshal(payment_system, #'fistful_base_PaymentSystemRef'{id = Ref}) ->
    #{
        id => unmarshal(string, Ref)
    };
unmarshal(issuer_country, V) when is_atom(V) ->
    V;
unmarshal(card_type, V) when is_atom(V) ->
    V;
unmarshal(crypto_wallet, #'fistful_base_CryptoWallet'{
    id = CryptoWalletID,
    currency = CryptoCurrencyRef
}) ->
    genlib_map:compact(#{
        id => unmarshal(string, CryptoWalletID),
        currency => unmarshal(crypto_currency, CryptoCurrencyRef)
    });
unmarshal(cash, #'fistful_base_Cash'{
    amount = Amount,
    currency = CurrencyRef
}) ->
    {unmarshal(amount, Amount), unmarshal(currency_ref, CurrencyRef)};
unmarshal(currency_ref, #'fistful_base_CurrencyRef'{
    symbolic_code = SymbolicCode
}) ->
    unmarshal(string, SymbolicCode);
unmarshal(crypto_currency, #'fistful_base_CryptoCurrencyRef'{id = Ref}) ->
    #{
        id => unmarshal(string, Ref)
    };
unmarshal(digital_wallet, #'fistful_base_DigitalWallet'{
    id = ID,
    token = Token,
    payment_service = PaymentService,
    account_name = AccountName,
    account_identity_number = AccountIdentityNumber
}) ->
    genlib_map:compact(#{
        id => unmarshal(string, ID),
        token => maybe_marshal(string, Token),
        payment_service => unmarshal(payment_service, PaymentService),
        account_name => unmarshal(string, AccountName),
        account_identity_number => unmarshal(string, AccountIdentityNumber)
    });
unmarshal(generic_resource, #'fistful_base_ResourceGenericData'{
    provider = PaymentService,
    data = Data
}) ->
    genlib_map:compact(#{
        data => maybe_marshal(content, Data),
        payment_service => unmarshal(payment_service, PaymentService)
    });
unmarshal(payment_service, #'fistful_base_PaymentServiceRef'{id = Ref}) ->
    #{
        id => unmarshal(string, Ref)
    };
unmarshal(content, #'fistful_base_Content'{
    type = Type,
    data = Data
}) ->
    #{
        type => unmarshal(string, Type),
        data => Data
    };
unmarshal(amount, V) ->
    unmarshal(integer, V);
unmarshal(failure, Failure) ->
    genlib_map:compact(#{
        code => unmarshal(string, Failure#'fistful_base_Failure'.code),
        reason => maybe_unmarshal(string, Failure#'fistful_base_Failure'.reason),
        sub => maybe_unmarshal(sub_failure, Failure#'fistful_base_Failure'.sub)
    });
unmarshal(sub_failure, Failure) ->
    genlib_map:compact(#{
        code => unmarshal(string, Failure#'fistful_base_SubFailure'.code),
        sub => maybe_unmarshal(sub_failure, Failure#'fistful_base_SubFailure'.sub)
    });
unmarshal(domain_revision, V) when is_integer(V) ->
    V;
unmarshal(party_revision, V) when is_integer(V) ->
    V;
unmarshal(string, V) when is_binary(V) ->
    V;
unmarshal(integer, V) when is_integer(V) ->
    V;
unmarshal(context, Ctx) when is_map(Ctx) ->
    maps:map(fun(_K, V) -> unmarshal(msgpack, V) end, Ctx);
unmarshal(msgpack, V) ->
    wapi_msgpack_codec:unmarshal(msgpack, V);
unmarshal(bool, V) when is_boolean(V) ->
    V.

maybe_unmarshal(_Type, undefined) ->
    undefined;
maybe_unmarshal(Type, Value) ->
    unmarshal(Type, Value).

maybe_marshal(_Type, undefined) ->
    undefined;
maybe_marshal(Type, Value) ->
    marshal(Type, Value).

-spec convert(Type :: atom(), Value :: any()) -> map().
convert(withdrawal_status, {pending, _}) ->
    #{<<"status">> => <<"Pending">>};
convert(withdrawal_status, {succeeded, _}) ->
    #{<<"status">> => <<"Succeeded">>};
convert(withdrawal_status, {failed, BaseFailure}) ->
    convert_failure(BaseFailure).

convert_failure(undefined) ->
    #{
        <<"status">> => <<"Failed">>,
        <<"failure">> => #{<<"code">> => <<"failed">>}
    };
%% Transform code format "Code:SubCode1:SubCode2" to
%% #{code => Code, subError => #{code => SubCode1, subError => #{code => SubCode2}}}
convert_failure(#'fistful_base_Failure'{code = Code, sub = Sub}) ->
    [MainCode | SubCodes] = binary:split(Code, <<":">>, [global]),
    #{
        <<"status">> => <<"Failed">>,
        <<"failure">> => genlib_map:compact(#{
            <<"code">> => MainCode,
            <<"subError">> => convert_subfailure(SubCodes, Sub)
        })
    }.

convert_subfailure([], SubFailure) ->
    convert_subfailure(SubFailure);
convert_subfailure([Code | Tail], SubFailure) when Tail =:= [<<>>] orelse Tail =:= [] ->
    genlib_map:compact(#{
        <<"code">> => Code,
        <<"subError">> => convert_subfailure(SubFailure)
    });
convert_subfailure([Code | Tail], SubFailure) ->
    genlib_map:compact(#{
        <<"code">> => Code,
        <<"subError">> => convert_subfailure(Tail, SubFailure)
    }).

convert_subfailure(undefined) ->
    undefined;
convert_subfailure(#'fistful_base_SubFailure'{code = Code, sub = Sub}) ->
    genlib_map:compact(#{
        <<"code">> => Code,
        <<"subError">> => convert_subfailure(Sub)
    }).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec bank_card_codec_test() -> _.

bank_card_codec_test() ->
    BankCard = #{
        token => <<"token">>,
        payment_system => #{id => <<"foo">>},
        bin => <<"12345">>,
        masked_pan => <<"7890">>,
        bank_name => <<"bank">>,
        issuer_country => zmb,
        card_type => credit_or_debit,
        exp_date => {12, 3456},
        cardholder_name => <<"name">>,
        bin_data_id => #{<<"foo">> => 1}
    },
    Type = {struct, struct, {fistful_fistful_base_thrift, 'BankCard'}},
    Binary = wapi_thrift_utils:serialize(Type, marshal(bank_card, BankCard)),
    Decoded = wapi_thrift_utils:deserialize(Type, Binary),
    ?assertEqual(
        Decoded,
        #'fistful_base_BankCard'{
            token = <<"token">>,
            payment_system = #'fistful_base_PaymentSystemRef'{id = <<"foo">>},
            bin = <<"12345">>,
            masked_pan = <<"7890">>,
            bank_name = <<"bank">>,
            issuer_country = zmb,
            card_type = credit_or_debit,
            exp_date = #'fistful_base_BankCardExpDate'{month = 12, year = 3456},
            cardholder_name = <<"name">>,
            bin_data_id = {obj, #{{str, <<"foo">>} => {i, 1}}}
        }
    ),
    ?assertEqual(BankCard, unmarshal(bank_card, Decoded)).

-spec crypto_wallet_codec_test() -> _.

crypto_wallet_codec_test() ->
    CryptoWallet = #{
        id => <<"token">>,
        currency => #{id => <<"BTC">>}
    },
    Type = {struct, struct, {fistful_fistful_base_thrift, 'CryptoWallet'}},
    Binary = wapi_thrift_utils:serialize(Type, marshal(crypto_wallet, CryptoWallet)),
    Decoded = wapi_thrift_utils:deserialize(Type, Binary),
    ?assertEqual(
        Decoded,
        #'fistful_base_CryptoWallet'{
            id = <<"token">>,
            currency = #'fistful_base_CryptoCurrencyRef'{id = <<"BTC">>}
        }
    ),
    ?assertEqual(CryptoWallet, unmarshal(crypto_wallet, Decoded)).

-endif.
