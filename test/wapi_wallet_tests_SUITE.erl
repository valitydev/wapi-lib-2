-module(wapi_wallet_tests_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_identity_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wallet_thrift.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

-export([init/1]).

-export([
    create_ok/1,
    create_fail_identity_notfound/1,
    create_fail_currency_notfound/1,
    create_fail_party_inaccessible/1,
    get_ok/1,
    get_fail_wallet_notfound/1,
    get_by_external_id_ok/1,
    get_account_ok/1,
    get_account_fail_get_context_wallet_notfound/1,
    get_account_fail_get_accountbalance_wallet_notfound/1,
    check_unknown_wallet_id/1
]).

-define(EMPTY_RESP(Code), {error, {Code, #{}}}).

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
            create_ok,
            create_fail_identity_notfound,
            create_fail_currency_notfound,
            create_fail_party_inaccessible,
            get_ok,
            get_fail_wallet_notfound,
            get_by_external_id_ok,
            get_account_ok,
            get_account_fail_get_context_wallet_notfound,
            get_account_fail_get_accountbalance_wallet_notfound,
            check_unknown_wallet_id
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
init_per_testcase(Name, C) ->
    C1 = wapi_ct_helper:makeup_cfg([wapi_ct_helper:test_case_name(Name), wapi_ct_helper:woody_ctx()], C),
    [{test_sup, wapi_ct_helper:start_mocked_service_sup(?MODULE)} | C1].

-spec end_per_testcase(test_case_name(), config()) -> ok.
end_per_testcase(_Name, C) ->
    _ = wapi_ct_helper:stop_mocked_service_sup(?config(test_sup, C)),
    ok.

%%% Tests

-spec create_ok(config()) -> _.
create_ok(C) ->
    PartyID = ?config(party, C),
    _ = create_wallet_start_mocks(C, fun() -> {ok, ?WALLET(PartyID)} end),
    {ok, _} = create_wallet_call_api(C).

-spec create_fail_identity_notfound(config()) -> _.
create_fail_identity_notfound(C) ->
    _ = create_wallet_start_mocks(C, fun() -> {throwing, #fistful_IdentityNotFound{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such identity">>}}},
        create_wallet_call_api(C)
    ).

-spec create_fail_currency_notfound(config()) -> _.
create_fail_currency_notfound(C) ->
    _ = create_wallet_start_mocks(C, fun() -> {throwing, #fistful_CurrencyNotFound{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Currency not supported">>}}},
        create_wallet_call_api(C)
    ).

-spec create_fail_party_inaccessible(config()) -> _.
create_fail_party_inaccessible(C) ->
    _ = create_wallet_start_mocks(C, fun() -> {throwing, #fistful_PartyInaccessible{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Identity inaccessible">>}}},
        create_wallet_call_api(C)
    ).

-spec get_ok(config()) -> _.
get_ok(C) ->
    PartyID = ?config(party, C),
    _ = get_wallet_start_mocks(C, fun() -> {ok, ?WALLET(PartyID)} end),
    {ok, _} = get_wallet_call_api(C).

-spec get_fail_wallet_notfound(config()) -> _.
get_fail_wallet_notfound(C) ->
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                % Чтобы тест не упал на авторизации нужно, чтобы были оба мока
                ('GetContext', _) -> {throwing, #fistful_WalletNotFound{}};
                ('Get', _) -> {throwing, #fistful_WalletNotFound{}}
            end}
        ],
        C
    ),
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    ?assertEqual(
        {error, {404, #{}}},
        get_wallet_call_api(C)
    ).

-spec get_by_external_id_ok(config()) -> _.
get_by_external_id_ok(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"GetWalletByExternalID">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun('GetInternalID', _) -> {ok, ?GET_INTERNAL_ID_RESULT} end},
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WALLET(PartyID)}
            end}
        ],
        C
    ),
    {ok, _} = call_api(
        fun swag_client_wallet_wallets_api:get_wallet_by_external_id/3,
        #{
            qs_val => #{
                <<"externalID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec get_account_ok(config()) -> _.
get_account_ok(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"GetWalletAccount">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WALLET(PartyID)};
                ('GetAccountBalance', _) -> {ok, ?ACCOUNT_BALANCE}
            end}
        ],
        C
    ),
    {ok, _} = get_account_call_api(C).

-spec get_account_fail_get_context_wallet_notfound(config()) -> _.
get_account_fail_get_context_wallet_notfound(C) ->
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                % Чтобы тест не упал на авторизации нужно, чтобы были оба мока
                ('GetContext', _) -> {throwing, #fistful_WalletNotFound{}};
                ('Get', _) -> {throwing, #fistful_WalletNotFound{}};
                ('GetAccountBalance', _) -> {ok, ?ACCOUNT_BALANCE}
            end}
        ],
        C
    ),
    ?assertEqual(
        ?EMPTY_RESP(401),
        get_account_call_api(C)
    ).

-spec get_account_fail_get_accountbalance_wallet_notfound(config()) -> _.
get_account_fail_get_accountbalance_wallet_notfound(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"GetWalletAccount">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WALLET(PartyID)};
                ('GetAccountBalance', _) -> {throwing, #fistful_WalletNotFound{}}
            end}
        ],
        C
    ),
    ?assertEqual(
        {error, {404, #{}}},
        get_account_call_api(C)
    ).

-spec check_unknown_wallet_id(config()) -> _.
check_unknown_wallet_id(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateWallet">>, ?STRING, PartyID, C),
    CounterRef = counters:new(1, []),
    ID0 = <<"Test0">>,
    ID1 = <<"Test1">>,
    Wallet0 = ?WALLET(PartyID),
    Wallet1 = Wallet0#wallet_WalletState{id = ID1},
    Wallet2 = Wallet1#wallet_WalletState{id = ID0, name = ?STRING2},
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
            {fistful_wallet, fun
                ('Create', _) ->
                    {ok, Wallet1};
                ('Get', {WID, _}) when WID =:= ID0 ->
                    {ok, Wallet2};
                ('Get', {WID, _}) when WID =:= ID1 ->
                    {throwing, #fistful_WalletNotFound{}}
            end}
        ],
        C
    ),
    {ok, #{
        <<"id">> := ID1
    }} = create_wallet_call_api(C).

%%

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

create_wallet_call_api(C) ->
    call_api(
        fun swag_client_wallet_wallets_api:create_wallet/3,
        #{
            body => #{
                <<"name">> => ?STRING,
                <<"identity">> => ?STRING,
                <<"currency">> => ?RUB,
                <<"metadata">> => #{
                    <<"somedata">> => ?STRING
                }
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

get_wallet_call_api(C) ->
    call_api(
        fun swag_client_wallet_wallets_api:get_wallet/3,
        #{
            binding => #{
                <<"walletID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

get_account_call_api(C) ->
    call_api(
        fun swag_client_wallet_wallets_api:get_wallet_account/3,
        #{
            binding => #{
                <<"walletID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

create_wallet_start_mocks(C, CreateResultFun) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_identity_op_ctx(<<"CreateWallet">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_identity, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?IDENTITY(PartyID)}
            end},
            {fistful_wallet, fun
                ('Create', _) -> CreateResultFun();
                ('Get', _) -> {throwing, #fistful_WalletNotFound{}}
            end}
        ],
        C
    ).

get_wallet_start_mocks(C, GetResultFun) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"GetWallet">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> GetResultFun()
            end}
        ],
        C
    ).
