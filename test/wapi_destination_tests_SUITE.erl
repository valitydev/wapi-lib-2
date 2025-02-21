-module(wapi_destination_tests_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_identity_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").
-include_lib("tds_proto/include/tds_storage_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([init/1]).

-export([create_extension_destination_ok_test/1]).
-export([create_extension_destination_fail_unknown_resource_test/1]).
-export([create_destination_ok_test/1]).
-export([create_destination_fail_resource_token_invalid_test/1]).
-export([create_destination_fail_resource_token_expire_test/1]).
-export([create_destination_fail_identity_notfound_test/1]).
-export([create_destination_fail_currency_notfound_test/1]).
-export([create_destination_fail_party_inaccessible_test/1]).
-export([create_destination_fail_withdrawal_method_test/1]).
-export([get_destination_ok_test/1]).
-export([get_destination_fail_notfound_test/1]).
-export([bank_card_resource_test/1]).
-export([bitcoin_resource_test/1]).
-export([digital_wallet_resource_test/1]).
-export([digital_wallet_w_token_resource_test/1]).
-export([check_unknown_destination_id/1]).

-define(GENERIC_RESOURCE_TYPE, <<"BankTransferGeneric">>).
-define(GENERIC_RESOURCE_NAME, <<"GenericBankAccount">>).

-type test_case_name() :: atom().
-type config() :: [{atom(), any()}].
-type group_name() :: atom().

-behaviour(supervisor).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 1, period => 1}, []}}.

-spec all() -> [{group, test_case_name()}].
all() ->
    [
        {group, base}
    ].

-spec groups() -> [{group_name(), list(), [test_case_name()]}].
groups() ->
    [
        {base, [], [
            create_extension_destination_ok_test,
            create_extension_destination_fail_unknown_resource_test,
            create_destination_ok_test,
            create_destination_fail_resource_token_invalid_test,
            create_destination_fail_resource_token_expire_test,
            create_destination_fail_identity_notfound_test,
            create_destination_fail_currency_notfound_test,
            create_destination_fail_party_inaccessible_test,
            create_destination_fail_withdrawal_method_test,
            get_destination_ok_test,
            get_destination_fail_notfound_test,
            bank_card_resource_test,
            bitcoin_resource_test,
            digital_wallet_resource_test,
            digital_wallet_w_token_resource_test,
            check_unknown_destination_id
        ]}
    ].

%%
%% starting/stopping
%%
-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    wapi_ct_helper:init_suite(?MODULE, C).

-spec end_per_suite(config()) -> _.
end_per_suite(C) ->
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(suite_test_sup, C)),
    _ = [application:stop(App) || App <- ?config(apps, C)],
    ok.

-spec init_per_group(group_name(), config()) -> config().
init_per_group(Group, Config) when Group =:= base ->
    Party = genlib:bsuuid(),
    Config1 = [{party, Party} | Config],
    GroupSup = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    _ = wapi_ct_helper_token_keeper:mock_user_session_token(Party, GroupSup),
    [{group_test_sup, GroupSup}, {context, wapi_ct_helper:get_context(?API_TOKEN)} | Config1];
init_per_group(_, Config) ->
    Config.

-spec end_per_group(group_name(), config()) -> _.
end_per_group(_Group, C) ->
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(group_test_sup, C)),
    ok.

-spec init_per_testcase(test_case_name(), config()) -> config().
init_per_testcase(Name, C) when
    Name =:= create_extension_destination_ok_test orelse
        Name =:= create_extension_destination_fail_unknown_resource_test
->
    meck:new(swag_server_wallet_schema, [no_link, passthrough]),
    meck:new(swag_client_wallet_schema, [no_link, passthrough]),
    makeup_and_start_mock_per_testcase(Name, C);
init_per_testcase(Name, C) ->
    makeup_and_start_mock_per_testcase(Name, C).

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(Name, C) when
    Name =:= create_extension_destination_ok_test orelse
        Name =:= create_extension_destination_fail_unknown_resource_test
->
    meck:unload(swag_server_wallet_schema),
    meck:unload(swag_client_wallet_schema),
    end_mock_per_testcase(C);
end_per_testcase(_Name, C) ->
    end_mock_per_testcase(C).

makeup_and_start_mock_per_testcase(Name, C) ->
    C1 = wapi_ct_helper:makeup_cfg([wapi_ct_helper:test_case_name(Name), wapi_ct_helper:woody_ctx()], C),
    TestSup = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    {ok, _} = supervisor:start_child(TestSup, lechiffre_child_spec(C)),
    [{test_sup, TestSup} | C1].

end_mock_per_testcase(C) ->
    wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

lechiffre_child_spec(Config) ->
    LechiffreOpts = #{
        encryption_source => {json, {file, wapi_ct_helper:get_keysource("jwk.publ.json", Config)}},
        decryption_sources => [
            {json, {file, wapi_ct_helper:get_keysource("jwk.priv.json", Config)}}
        ]
    },
    lechiffre:child_spec(lechiffre, LechiffreOpts).

%%% Tests

-spec create_extension_destination_ok_test(config()) -> _.
create_extension_destination_ok_test(C) ->
    Ref = <<"#/definitions/", ?GENERIC_RESOURCE_NAME/binary>>,
    ResourceSchema = #{
        <<"allOf">> =>
            [
                #{
                    <<"$ref">> => <<"#/definitions/DestinationResource">>
                },
                #{
                    <<"$ref">> => Ref
                }
            ],
        <<"x-vality-genericMethod">> =>
            #{
                <<"schema">> =>
                    #{
                        <<"id">> => <<"https://some.link">>,
                        <<"allOf">> =>
                            [
                                #{
                                    <<"$ref">> => Ref
                                }
                            ]
                    }
            }
    },
    mock_generic_schema(ResourceSchema),
    Destination = make_destination(C, generic),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {ok, _},
        create_destination_call_api(C, Destination)
    ).

-spec create_extension_destination_fail_unknown_resource_test(config()) -> _.
create_extension_destination_fail_unknown_resource_test(C) ->
    Ref = <<"#/definitions/", ?GENERIC_RESOURCE_NAME/binary>>,
    ResourceSchema = #{
        <<"allOf">> => [
            #{
                <<"$ref">> => <<"#/definitions/DestinationResource">>
            },
            #{
                <<"$ref">> => Ref
            }
        ]
    },
    mock_generic_schema(ResourceSchema),
    Destination = make_destination(C, generic),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {error,
            {400, #{
                <<"errorType">> := <<"SchemaViolated">>,
                <<"description">> := <<"Unknown resource">>
            }}},
        create_destination_call_api(C, Destination)
    ).

-spec create_destination_ok_test(config()) -> _.
create_destination_ok_test(C) ->
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {ok, _},
        create_destination_call_api(C, Destination)
    ).

-spec create_destination_fail_resource_token_invalid_test(config()) -> _.
create_destination_fail_resource_token_invalid_test(C) ->
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {error,
            {400, #{
                <<"errorType">> := <<"InvalidResourceToken">>,
                <<"name">> := <<"BankCardDestinationResource">>
            }}},
        create_destination_call_api(C, Destination, <<"v1.InvalidResourceToken">>)
    ).

-spec create_destination_fail_resource_token_expire_test(config()) -> _.
create_destination_fail_resource_token_expire_test(C) ->
    ExpiredDeadline = wapi_utils:deadline_from_timeout(0),
    InvalidResourceToken = wapi_crypto:create_resource_token({bank_card, ?BANK_CARD}, ExpiredDeadline),
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {error,
            {400, #{
                <<"errorType">> := <<"InvalidResourceToken">>,
                <<"name">> := <<"BankCardDestinationResource">>
            }}},
        create_destination_call_api(C, Destination, InvalidResourceToken)
    ).

-spec create_destination_fail_identity_notfound_test(config()) -> _.
create_destination_fail_identity_notfound_test(C) ->
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {throwing, #fistful_IdentityNotFound{}}),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such identity">>}}},
        create_destination_call_api(C, Destination)
    ).

-spec create_destination_fail_currency_notfound_test(config()) -> _.
create_destination_fail_currency_notfound_test(C) ->
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {throwing, #fistful_CurrencyNotFound{}}),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Currency not supported">>}}},
        create_destination_call_api(C, Destination)
    ).

-spec create_destination_fail_party_inaccessible_test(config()) -> _.
create_destination_fail_party_inaccessible_test(C) ->
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {throwing, #fistful_PartyInaccessible{}}),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Identity inaccessible">>}}},
        create_destination_call_api(C, Destination)
    ).

-spec create_destination_fail_withdrawal_method_test(config()) -> _.
create_destination_fail_withdrawal_method_test(C) ->
    Destination = make_destination(C, bank_card),
    _ = create_destination_start_mocks(C, {throwing, #fistful_ForbiddenWithdrawalMethod{}}),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Resource type not allowed">>}}},
        create_destination_call_api(C, Destination)
    ).

-spec get_destination_ok_test(config()) -> _.
get_destination_ok_test(C) ->
    Destination = make_destination(C, bank_card),
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_destination_op_ctx(<<"GetDestination">>, ?STRING, PartyID, C),
    _ = get_destination_start_mocks(C, {ok, Destination}),
    ?assertMatch(
        {ok, _},
        get_destination_call_api(C)
    ).

-spec get_destination_fail_notfound_test(config()) -> _.
get_destination_fail_notfound_test(C) ->
    _ = get_destination_start_mocks(C, {throwing, #fistful_DestinationNotFound{}}),
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    ?assertEqual(
        {error, {404, #{}}},
        get_destination_call_api(C)
    ).

-spec bank_card_resource_test(config()) -> _.
bank_card_resource_test(C) ->
    {ok, Resource, SwagResource} = do_destination_lifecycle(bank_card, C),
    {bank_card, #'fistful_base_ResourceBankCard'{bank_card = R}} = Resource,
    ?assertEqual(<<"BankCardDestinationResource">>, maps:get(<<"type">>, SwagResource)),
    ?assertEqual(R#'fistful_base_BankCard'.token, maps:get(<<"token">>, SwagResource)),
    ?assertEqual(R#'fistful_base_BankCard'.bin, maps:get(<<"bin">>, SwagResource)),
    ?assertEqual(R#'fistful_base_BankCard'.masked_pan, maps:get(<<"lastDigits">>, SwagResource)).

-spec bitcoin_resource_test(config()) -> _.
bitcoin_resource_test(C) ->
    {ok, Resource, SwagResource} = do_destination_lifecycle(bitcoin, C),
    ?assertEqual(<<"CryptoWalletDestinationResource">>, maps:get(<<"type">>, SwagResource)),
    ?assertEqual(<<"bitcoin">>, maps:get(<<"currency">>, SwagResource)),
    {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{crypto_wallet = #'fistful_base_CryptoWallet'{id = ID}}} =
        Resource,
    ?assertEqual(ID, maps:get(<<"id">>, SwagResource)).

-spec digital_wallet_resource_test(config()) -> _.
digital_wallet_resource_test(C) ->
    {ok, Resource, SwagResource} = do_destination_lifecycle(digital_wallet, C),
    ?assertEqual(<<"DigitalWalletDestinationResource">>, maps:get(<<"type">>, SwagResource)),
    ?assertEqual(<<"nomoney">>, maps:get(<<"provider">>, SwagResource)),
    ?assertEqual(<<"AccountNAME">>, maps:get(<<"accountName">>, SwagResource)),
    ?assertEqual(<<"AccountIdentityNumber">>, maps:get(<<"accountIdentityNumber">>, SwagResource)),
    {digital_wallet, #'fistful_base_ResourceDigitalWallet'{digital_wallet = #'fistful_base_DigitalWallet'{id = ID}}} =
        Resource,
    ?assertEqual(ID, maps:get(<<"id">>, SwagResource)).

-spec digital_wallet_w_token_resource_test(config()) -> _.
digital_wallet_w_token_resource_test(C) ->
    Runner = self(),
    PartyID = wapi_ct_helper:cfg(party, C),
    Token = <<"YISSTOKEN">>,
    Provider = <<"yissmoney">>,
    Resource = #{
        <<"type">> => <<"DigitalWalletDestinationResource">>,
        <<"id">> => ?STRING,
        <<"provider">> => Provider,
        <<"token">> => Token,
        <<"accountName">> => ?STRING,
        <<"accountIdentityNumber">> => ?STRING
    },
    Destination = #{
        <<"name">> => ?STRING,
        <<"identity">> => ?STRING,
        <<"currency">> => ?RUB,
        <<"resource">> => Resource
    },
    _ = wapi_ct_helper:mock_services(
        [
            {token_storage, fun('PutToken', {ID, #tds_Token{content = TokenStored}}) ->
                _ = Runner ! {token, {ID, TokenStored}},
                {ok, ok}
            end},
            {bender, fun
                ('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT};
                ('GetInternalID', _) -> {ok, ?GET_INTERNAL_ID_RESULT}
            end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_destination, fun
                ('Create', _) ->
                    {ok, ?DESTINATION(PartyID, ?RESOURCE_DIGITAL_WALLET)};
                ('Get', _) ->
                    {throwing, #fistful_DestinationNotFound{}}
            end}
        ],
        C
    ),
    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateDestination">>, ?STRING, PartyID, C),
    {ok, #{<<"resource">> := ResourceOut}} = call_api(
        fun swag_client_wallet_withdrawals_api:create_destination/3,
        #{body => Destination},
        wapi_ct_helper:cfg(context, C)
    ),
    ?assertEqual(undefined, maps:get(<<"token">>, ResourceOut, undefined)),
    receive
        {token, {ID, TokenStored}} ->
            ?assertEqual(Token, TokenStored),
            ?assertNotEqual(ID, Token)
    after 1000 ->
        error('missing token storage interaction')
    end.

-spec check_unknown_destination_id(config()) -> _.
check_unknown_destination_id(C) ->
    PartyID = ?config(party, C),

    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateDestination">>, ?STRING, PartyID, C),

    CounterRef = counters:new(1, []),
    ID0 = <<"Test0">>,
    ID1 = <<"Test1">>,
    Destination0 = ?DESTINATION(PartyID),
    Destination1 = Destination0#destination_DestinationState{id = ID1},
    Destination2 = Destination1#destination_DestinationState{id = ID0, name = ?STRING2},
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) ->
                CID = counters:get(CounterRef, 1),
                BinaryCID = erlang:integer_to_binary(CID),
                ok = counters:add(CounterRef, 1, 1),
                {ok, ?GENERATE_ID_RESULT(<<"Test", BinaryCID/binary>>)}
            end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_destination, fun
                ('Create', _) ->
                    {ok, Destination1};
                ('Get', {WID, _}) when WID =:= ID0 ->
                    {ok, Destination2};
                ('Get', {WID, _}) when WID =:= ID1 ->
                    {throwing, #fistful_DestinationNotFound{}}
            end}
        ],
        C
    ),
    ?assertMatch(
        {ok, #{<<"id">> := ID1}},
        create_destination_call_api(C, Destination0)
    ).

%%

do_destination_lifecycle(ResourceType, C) ->
    PartyID = wapi_ct_helper:cfg(party, C),
    Identity = generate_identity(PartyID),
    Resource = generate_resource(ResourceType),
    Context = generate_context(PartyID),
    Destination = generate_destination(Identity#identity_IdentityState.id, Resource, Context),
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun
                ('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT};
                ('GetInternalID', _) -> {ok, ?GET_INTERNAL_ID_RESULT}
            end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_destination, fun
                ('Create', _) -> {ok, Destination};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, Destination}
            end}
        ],
        C
    ),
    Sup0 = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateDestination">>, ?STRING, PartyID, Sup0),
    {ok, CreateResult} = call_api(
        fun swag_client_wallet_withdrawals_api:create_destination/3,
        #{
            body => build_destination_spec(Destination, undefined)
        },
        wapi_ct_helper:cfg(context, C)
    ),
    exit(Sup0, kill),
    _ = timer:sleep(1000),
    Sup1 = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    _ = wapi_ct_helper_bouncer:mock_assert_destination_op_ctx(<<"GetDestination">>, ?STRING, PartyID, Sup1),
    {ok, GetResult} = call_api(
        fun swag_client_wallet_withdrawals_api:get_destination/3,
        #{
            binding => #{
                <<"destinationID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ),
    ?assertEqual(CreateResult, GetResult),
    exit(Sup1, kill),
    _ = timer:sleep(1000),
    Sup2 = wapi_ct_helper:start_mocked_service_sup(?MODULE),
    _ = wapi_ct_helper_bouncer:mock_assert_destination_op_ctx(<<"GetDestinationByExternalID">>, ?STRING, PartyID, Sup2),
    {ok, GetByIDResult} = call_api(
        fun swag_client_wallet_withdrawals_api:get_destination_by_external_id/3,
        #{
            binding => #{
                <<"externalID">> => Destination#destination_DestinationState.external_id
            }
        },
        wapi_ct_helper:cfg(context, C)
    ),
    exit(Sup2, kill),
    _ = timer:sleep(1000),
    ?assertEqual(GetResult, GetByIDResult),
    ?assertEqual(Destination#destination_DestinationState.id, maps:get(<<"id">>, CreateResult)),
    ?assertEqual(Destination#destination_DestinationState.external_id, maps:get(<<"externalID">>, CreateResult)),
    ?assertEqual(Identity#identity_IdentityState.id, maps:get(<<"identity">>, CreateResult)),
    Account = Destination#destination_DestinationState.account,
    ?assertEqual(
        Account#account_Account.currency#fistful_base_CurrencyRef.symbolic_code,
        maps:get(<<"currency">>, CreateResult)
    ),
    ?assertEqual(<<"Authorized">>, maps:get(<<"status">>, CreateResult)),
    ?assertEqual(false, maps:get(<<"isBlocked">>, CreateResult)),
    ?assertEqual(Destination#destination_DestinationState.created_at, maps:get(<<"createdAt">>, CreateResult)),
    ?assertEqual(#{<<"key">> => <<"val">>}, maps:get(<<"metadata">>, CreateResult)),
    {ok, Resource, maps:get(<<"resource">>, CreateResult)}.

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

build_destination_spec(D, undefined) ->
    build_destination_spec(D, D#destination_DestinationState.resource);
build_destination_spec(D, Resource) ->
    #{
        <<"name">> => D#destination_DestinationState.name,
        <<"identity">> => (D#destination_DestinationState.account)#account_Account.identity,
        <<"currency">> =>
            D#destination_DestinationState.account#account_Account.currency#fistful_base_CurrencyRef.symbolic_code,
        <<"externalID">> => D#destination_DestinationState.external_id,
        <<"resource">> => build_resource_spec(Resource),
        <<"additionalAuthData">> => #{
            <<"type">> => <<"SenderReceiverDestinationAuthData">>,
            <<"senderToken">> => <<"SenderToken">>,
            <<"receiverToken">> => <<"ReceiverToken">>
        }
    }.

build_resource_spec({bank_card, R}) ->
    #{
        <<"type">> => <<"BankCardDestinationResource">>,
        <<"token">> => wapi_crypto:create_resource_token(
            {bank_card, R#fistful_base_ResourceBankCard.bank_card}, undefined
        )
    };
build_resource_spec({crypto_wallet, R}) ->
    CurrencyRef = (R#'fistful_base_ResourceCryptoWallet'.crypto_wallet)#'fistful_base_CryptoWallet'.currency,
    #{
        <<"type">> => <<"CryptoWalletDestinationResource">>,
        <<"id">> => R#fistful_base_ResourceCryptoWallet.crypto_wallet#fistful_base_CryptoWallet.id,
        <<"currency">> => CurrencyRef#fistful_base_CryptoCurrencyRef.id
    };
build_resource_spec({digital_wallet, #'fistful_base_ResourceDigitalWallet'{digital_wallet = DW}}) ->
    #{
        <<"type">> => <<"DigitalWalletDestinationResource">>,
        <<"id">> => DW#fistful_base_DigitalWallet.id,
        <<"provider">> => DW#fistful_base_DigitalWallet.payment_service#fistful_base_PaymentServiceRef.id
    };
build_resource_spec(
    {generic, #fistful_base_ResourceGeneric{generic = #fistful_base_ResourceGenericData{data = Data}}}
) ->
    #fistful_base_Content{data = Params} = Data,
    jsx:decode(Params);
build_resource_spec(Token) ->
    #{
        <<"type">> => <<"BankCardDestinationResource">>,
        <<"token">> => Token
    }.

uniq() ->
    genlib:bsuuid().

generate_identity(PartyID) ->
    #identity_IdentityState{
        id = ?STRING,
        name = uniq(),
        party_id = PartyID,
        provider_id = uniq(),
        context = generate_context(PartyID)
    }.

generate_context(PartyID) ->
    #{
        ?CTX_NS =>
            {obj, #{
                {str, <<"owner">>} => {str, PartyID},
                {str, <<"name">>} => {str, uniq()},
                {str, <<"metadata">>} => {obj, #{{str, <<"key">>} => {str, <<"val">>}}}
            }}
    }.

generate_destination(IdentityID, Resource, Context) ->
    ID = ?STRING,
    #destination_DestinationState{
        id = ID,
        name = uniq(),
        status = {authorized, #destination_Authorized{}},
        account = #account_Account{
            id = ID,
            identity = IdentityID,
            currency = #'fistful_base_CurrencyRef'{
                symbolic_code = <<"RUB">>
            },
            accounter_account_id = 123
        },
        resource = Resource,
        external_id = ?STRING,
        created_at = <<"2016-03-22T06:12:27Z">>,
        blocking = unblocked,
        metadata = #{<<"key">> => {str, <<"val">>}},
        context = Context,
        auth_data =
            {sender_receiver, #destination_SenderReceiverAuthData{
                sender = <<"SenderToken">>,
                receiver = <<"ReceiverToken">>
            }}
    }.

generate_resource(generic) ->
    Data = jsx:encode(#{
        <<"type">> => ?GENERIC_RESOURCE_TYPE,
        <<"accountNumber">> => <<"1233123">>
    }),
    ID = <<"https://some.link">>,
    Type = <<"application/schema-instance+json; schema=", ID/binary>>,
    {generic, #'fistful_base_ResourceGeneric'{
        generic = #'fistful_base_ResourceGenericData'{
            data = #'fistful_base_Content'{type = Type, data = Data},
            provider = #'fistful_base_PaymentServiceRef'{id = ?GENERIC_RESOURCE_TYPE}
        }
    }};
generate_resource(bank_card) ->
    {bank_card, #'fistful_base_ResourceBankCard'{
        bank_card = #'fistful_base_BankCard'{
            token = uniq(),
            bin = <<"424242">>,
            masked_pan = <<"4242">>,
            bank_name = uniq(),
            payment_system = #'fistful_base_PaymentSystemRef'{id = <<"foo">>},
            issuer_country = rus,
            card_type = debit,
            exp_date = #'fistful_base_BankCardExpDate'{
                month = 12,
                year = 2200
            }
        }
    }};
generate_resource(bitcoin) ->
    {crypto_wallet, #'fistful_base_ResourceCryptoWallet'{
        crypto_wallet = #'fistful_base_CryptoWallet'{
            id = uniq(),
            currency = #'fistful_base_CryptoCurrencyRef'{id = <<"bitcoin">>}
        }
    }};
generate_resource(digital_wallet) ->
    {digital_wallet, #'fistful_base_ResourceDigitalWallet'{
        digital_wallet = #'fistful_base_DigitalWallet'{
            id = uniq(),
            payment_service = #'fistful_base_PaymentServiceRef'{id = generate_digital_wallet_provider()},
            account_name = <<"AccountNAME">>,
            account_identity_number = <<"AccountIdentityNumber">>
        }
    }}.

generate_digital_wallet_provider() ->
    <<"nomoney">>.

make_destination(C, ResourceType) ->
    PartyID = ?config(party, C),
    Identity = generate_identity(PartyID),
    Resource = generate_resource(ResourceType),
    Context = generate_context(PartyID),
    generate_destination(Identity#identity_IdentityState.id, Resource, Context).

create_destination_start_mocks(C, CreateDestinationResult) ->
    PartyID = ?config(party, C),

    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateDestination">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_destination, fun
                ('Create', _) -> CreateDestinationResult;
                ('Get', _) -> {throwing, #fistful_DestinationNotFound{}}
            end}
        ],
        C
    ).

get_destination_start_mocks(C, GetDestinationResult) ->
    PartyID = ?config(party, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_destination, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> GetDestinationResult
            end}
        ],
        C
    ).

create_destination_call_api(C, Destination) ->
    create_destination_call_api(C, Destination, undefined).

create_destination_call_api(C, Destination, Resource) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:create_destination/3,
        #{
            body => build_destination_spec(Destination, Resource)
        },
        wapi_ct_helper:cfg(context, C)
    ).

get_destination_call_api(C) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:get_destination/3,
        #{
            binding => #{
                <<"destinationID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

mock_generic_schema(ResourceSchema) ->
    Raw = swag_server_wallet_schema:get(),
    Definitions = maps:get(<<"definitions">>, Raw),
    Get = fun() ->
        Raw#{
            <<"definitions">> => Definitions#{
                ?GENERIC_RESOURCE_TYPE => ResourceSchema,
                ?GENERIC_RESOURCE_NAME => #{
                    <<"type">> => <<"object">>,
                    <<"required">> => [<<"accountNumber">>],
                    <<"properties">> => #{
                        <<"accountNumber">> => #{
                            <<"type">> => <<"string">>,
                            <<"example">> => <<"0071717">>,
                            <<"pattern">> => <<"^\\d{7,8}$">>
                        }
                    }
                },
                <<"DestinationResource">> => #{
                    <<"type">> => <<"object">>,
                    <<"required">> => [<<"type">>],
                    <<"discriminator">> => <<"type">>,
                    <<"properties">> => #{
                        <<"type">> => #{
                            <<"type">> => <<"string">>,
                            <<"enum">> => [?GENERIC_RESOURCE_TYPE]
                        }
                    }
                }
            }
        }
    end,
    meck:expect(swag_server_wallet_schema, get, Get),
    meck:expect(swag_client_wallet_schema, get, Get).
