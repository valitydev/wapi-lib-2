-module(wapi_w2w_tests_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_cashflow_thrift.hrl").
-include_lib("fistful_proto/include/fistful_w2w_transfer_thrift.hrl").
-include_lib("fistful_proto/include/fistful_w2w_status_thrift.hrl").
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
    create_ok_test/1,
    create_fail_unauthorized_wallet_test/1,
    create_fail_wallet_notfound_test/1,
    create_fail_invalid_operation_amount_test/1,
    create_fail_forbidden_operation_currency_test/1,
    create_fail_inconsistent_w2w_transfer_currency_test/1,
    create_fail_wallet_inaccessible_test/1,
    get_ok_test/1,
    get_fail_w2w_notfound_test/1,
    check_unknown_w2w_id/1
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
            create_ok_test,
            create_fail_unauthorized_wallet_test,
            create_fail_wallet_notfound_test,
            create_fail_invalid_operation_amount_test,
            create_fail_forbidden_operation_currency_test,
            create_fail_inconsistent_w2w_transfer_currency_test,
            create_fail_wallet_inaccessible_test,
            get_ok_test,
            get_fail_w2w_notfound_test,
            check_unknown_w2w_id
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

-spec create_ok_test(config()) -> _.
create_ok_test(C) ->
    PartyID = ?config(party, C),
    _ = create_w2_w_transfer_start_mocks(C, fun() -> {ok, ?W2W_TRANSFER(PartyID)} end),
    {ok, _} = create_w2_w_transfer_call_api(C).

-spec create_fail_unauthorized_wallet_test(config()) -> _.
create_fail_unauthorized_wallet_test(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(<<"someotherparty">>)};
                ('Get', _) -> {ok, ?WALLET(<<"someotherparty">>)}
            end},
            {fistful_w2w_transfer, fun('Create', _) -> {ok, ?W2W_TRANSFER(PartyID)} end}
        ],
        C
    ),
    ?assertEqual(
        ?EMPTY_RESP(401),
        create_w2_w_transfer_call_api(C)
    ).

-spec create_fail_wallet_notfound_test(config()) -> _.
create_fail_wallet_notfound_test(C) ->
    WalletNotFoundException = #fistful_WalletNotFound{
        id = ?STRING
    },
    _ = create_w2_w_transfer_start_mocks(C, fun() -> {throwing, WalletNotFoundException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such wallet sender">>}}},
        create_w2_w_transfer_call_api(C)
    ).

-spec create_fail_invalid_operation_amount_test(config()) -> _.
create_fail_invalid_operation_amount_test(C) ->
    InvalidOperationAmountException = #fistful_InvalidOperationAmount{
        amount = ?CASH
    },
    _ = create_w2_w_transfer_start_mocks(C, fun() -> {throwing, InvalidOperationAmountException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Bad transfer amount">>}}},
        create_w2_w_transfer_call_api(C)
    ).

-spec create_fail_forbidden_operation_currency_test(config()) -> _.
create_fail_forbidden_operation_currency_test(C) ->
    ForbiddenOperationCurrencyException = #fistful_ForbiddenOperationCurrency{
        currency = #'fistful_base_CurrencyRef'{symbolic_code = ?USD},
        allowed_currencies = [
            #'fistful_base_CurrencyRef'{symbolic_code = ?RUB}
        ]
    },
    _ = create_w2_w_transfer_start_mocks(C, fun() -> {throwing, ForbiddenOperationCurrencyException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Currency not allowed">>}}},
        create_w2_w_transfer_call_api(C)
    ).

-spec create_fail_inconsistent_w2w_transfer_currency_test(config()) -> _.
create_fail_inconsistent_w2w_transfer_currency_test(C) ->
    InconsistentW2WCurrencyException = #w2w_transfer_InconsistentW2WTransferCurrency{
        w2w_transfer_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?USD
        },
        wallet_from_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?RUB
        },
        wallet_to_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?RUB
        }
    },
    _ = create_w2_w_transfer_start_mocks(C, fun() -> {throwing, InconsistentW2WCurrencyException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Inconsistent currency">>}}},
        create_w2_w_transfer_call_api(C)
    ).

-spec create_fail_wallet_inaccessible_test(config()) -> _.
create_fail_wallet_inaccessible_test(C) ->
    WalletInaccessibleException = #fistful_WalletInaccessible{
        id = ?STRING
    },
    _ = create_w2_w_transfer_start_mocks(C, fun() -> {throwing, WalletInaccessibleException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Wallet inaccessible">>}}},
        create_w2_w_transfer_call_api(C)
    ).

-spec get_ok_test(config()) -> _.
get_ok_test(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_w2w_transfer_op_ctx(<<"GetW2WTransfer">>, ?STRING, PartyID, C),
    _ = get_w2_w_transfer_start_mocks(C, fun() -> {ok, ?W2W_TRANSFER(PartyID)} end),
    {ok, _} = get_w2_w_transfer_call_api(C).

-spec get_fail_w2w_notfound_test(config()) -> _.
get_fail_w2w_notfound_test(C) ->
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    _ = get_w2_w_transfer_start_mocks(C, fun() -> {throwing, #fistful_W2WNotFound{}} end),
    ?assertMatch(
        {error, {404, #{}}},
        get_w2_w_transfer_call_api(C)
    ).

-spec check_unknown_w2w_id(config()) -> _.
check_unknown_w2w_id(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"CreateW2WTransfer">>, ?STRING, PartyID, C),
    CounterRef = counters:new(1, []),
    ID0 = <<"Test0">>,
    ID1 = <<"Test1">>,
    W2WTransfer0 = ?W2W_TRANSFER(PartyID),
    W2WTransfer1 = W2WTransfer0#w2w_transfer_W2WTransferState{id = ID1},
    W2WTransfer2 = W2WTransfer1#w2w_transfer_W2WTransferState{id = ID0, wallet_from_id = ?STRING2},
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) ->
                CID = counters:get(CounterRef, 1),
                BinaryCID = erlang:integer_to_binary(CID),
                ok = counters:add(CounterRef, 1, 1),
                {ok, ?GENERATE_ID_RESULT(<<"Test", BinaryCID/binary>>)}
            end},
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WALLET(PartyID)}
            end},
            {fistful_w2w_transfer, fun
                ('Create', _) ->
                    {ok, W2WTransfer1};
                ('Get', {WID, _}) when WID =:= ID0 ->
                    {ok, W2WTransfer2};
                ('Get', {WID, _}) when WID =:= ID1 ->
                    {throwing, #fistful_W2WNotFound{}}
            end}
        ],
        C
    ),
    {ok, #{
        <<"id">> := ID1
    }} = create_w2_w_transfer_call_api(C).

%%

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

create_w2_w_transfer_call_api(C) ->
    call_api(
        fun swag_client_wallet_w2_w_api:create_w2_w_transfer/3,
        #{
            body => #{
                <<"sender">> => ?STRING,
                <<"receiver">> => ?STRING,
                <<"body">> => #{
                    <<"amount">> => ?INTEGER,
                    <<"currency">> => ?RUB
                }
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

get_w2_w_transfer_call_api(C) ->
    call_api(
        fun swag_client_wallet_w2_w_api:get_w2_w_transfer/3,
        #{
            binding => #{
                <<"w2wTransferID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

create_w2_w_transfer_start_mocks(C, CreateResultFun) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_wallet_op_ctx(<<"CreateW2WTransfer">>, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_wallet, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WALLET(PartyID)}
            end},
            {fistful_w2w_transfer, fun
                ('Create', _) -> CreateResultFun();
                ('Get', _) -> {throwing, #fistful_W2WNotFound{}}
            end}
        ],
        C
    ).

get_w2_w_transfer_start_mocks(C, GetResultFun) ->
    PartyID = ?config(party, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_w2w_transfer, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> GetResultFun()
            end}
        ],
        C
    ).
