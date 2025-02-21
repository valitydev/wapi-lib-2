-module(wapi_withdrawal_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("wapi_wallet_dummy_data.hrl").
-include_lib("wapi_bouncer_data.hrl").

-include_lib("fistful_proto/include/fistful_fistful_base_thrift.hrl").
-include_lib("fistful_proto/include/fistful_fistful_thrift.hrl").
-include_lib("fistful_proto/include/fistful_account_thrift.hrl").
-include_lib("fistful_proto/include/fistful_cashflow_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wallet_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_thrift.hrl").
-include_lib("fistful_proto/include/fistful_wthd_status_thrift.hrl").
-include_lib("fistful_proto/include/fistful_destination_thrift.hrl").

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
    create_fail_wallet_notfound/1,
    create_fail_destination_notfound/1,
    create_fail_destination_unauthorized/1,
    create_fail_destination_withdrawal_method/1,
    create_fail_forbidden_operation_currency/1,
    create_fail_forbidden_operation_amount/1,
    create_fail_invalid_operation_amount/1,
    create_fail_inconsistent_withdrawal_currency/1,
    create_fail_no_destination_resource_info/1,
    create_fail_identity_providers_mismatch/1,
    create_fail_wallet_inaccessible/1,
    get_ok/1,
    get_failed/1,
    get_failed_wo_colon/1,
    get_fail_withdrawal_notfound/1,
    get_by_external_id_ok/1,
    create_quote_ok/1,
    get_quote_fail_wallet_notfound/1,
    get_quote_fail_destination_notfound/1,
    get_quote_fail_destination_unauthorized/1,
    get_quote_fail_destination_withdrawal_method/1,
    get_quote_fail_forbidden_operation_currency/1,
    get_quote_fail_forbidden_operation_amount/1,
    get_quote_fail_invalid_operation_amount/1,
    get_quote_fail_inconsistent_withdrawal_currency/1,
    get_quote_fail_identity_provider_mismatch/1,
    get_event_ok/1,
    get_events_ok/1,
    get_events_fail_withdrawal_notfound/1,
    check_unknown_withdrawal_id/1
]).

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
            create_fail_wallet_notfound,
            create_fail_destination_notfound,
            create_fail_destination_unauthorized,
            create_fail_destination_withdrawal_method,
            create_fail_forbidden_operation_currency,
            create_fail_forbidden_operation_amount,
            create_fail_invalid_operation_amount,
            create_fail_inconsistent_withdrawal_currency,
            create_fail_no_destination_resource_info,
            create_fail_identity_providers_mismatch,
            create_fail_wallet_inaccessible,
            get_ok,
            get_failed,
            get_failed_wo_colon,
            get_fail_withdrawal_notfound,
            get_by_external_id_ok,
            create_quote_ok,
            get_quote_fail_wallet_notfound,
            get_quote_fail_destination_notfound,
            get_quote_fail_destination_unauthorized,
            get_quote_fail_destination_withdrawal_method,
            get_quote_fail_forbidden_operation_currency,
            get_quote_fail_forbidden_operation_amount,
            get_quote_fail_invalid_operation_amount,
            get_quote_fail_inconsistent_withdrawal_currency,
            get_quote_fail_identity_provider_mismatch,
            get_event_ok,
            get_events_ok,
            get_events_fail_withdrawal_notfound,
            check_unknown_withdrawal_id
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
init_per_group(Group, Config) when Group =:= base; Group =:= base2 ->
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
    _ = create_withdrawal_start_mocks(C, fun() -> {ok, ?WITHDRAWAL(PartyID)} end),
    {ok, _} = create_withdrawal_call_api(C).

-spec create_fail_wallet_notfound(config()) -> _.
create_fail_wallet_notfound(C) ->
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, #fistful_WalletNotFound{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such wallet">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_destination_notfound(config()) -> _.
create_fail_destination_notfound(C) ->
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, #fistful_DestinationNotFound{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such destination">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_destination_unauthorized(config()) -> _.
create_fail_destination_unauthorized(C) ->
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, #fistful_DestinationUnauthorized{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Destination unauthorized">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_destination_withdrawal_method(config()) -> _.
create_fail_destination_withdrawal_method(C) ->
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, #fistful_ForbiddenWithdrawalMethod{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Destination uses resource no longer allowed">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_forbidden_operation_currency(config()) -> _.
create_fail_forbidden_operation_currency(C) ->
    ForbiddenOperationCurrencyException = #fistful_ForbiddenOperationCurrency{
        currency = #'fistful_base_CurrencyRef'{symbolic_code = ?USD},
        allowed_currencies = [
            #'fistful_base_CurrencyRef'{symbolic_code = ?RUB}
        ]
    },
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, ForbiddenOperationCurrencyException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Forbidden currency">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_forbidden_operation_amount(config()) -> _.
create_fail_forbidden_operation_amount(C) ->
    ForbiddenOperationAmountException = #fistful_ForbiddenOperationAmount{
        amount = ?CASH,
        allowed_range = #'fistful_base_CashRange'{
            upper = {inclusive, ?CASH},
            lower = {inclusive, ?CASH}
        }
    },
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, ForbiddenOperationAmountException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid cash amount">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_invalid_operation_amount(config()) -> _.
create_fail_invalid_operation_amount(C) ->
    InvalidOperationAmountException = #fistful_InvalidOperationAmount{
        amount = ?CASH
    },
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, InvalidOperationAmountException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid cash amount">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_inconsistent_withdrawal_currency(config()) -> _.
create_fail_inconsistent_withdrawal_currency(C) ->
    InconsistentWithdrawalCurrencyException = #wthd_InconsistentWithdrawalCurrency{
        withdrawal_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?USD
        },
        destination_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?RUB
        },
        wallet_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?RUB
        }
    },
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, InconsistentWithdrawalCurrencyException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid currency">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_no_destination_resource_info(config()) -> _.
create_fail_no_destination_resource_info(C) ->
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, #wthd_NoDestinationResourceInfo{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Unknown card issuer">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_identity_providers_mismatch(config()) -> _.
create_fail_identity_providers_mismatch(C) ->
    IdentityProviderMismatchException = #wthd_IdentityProvidersMismatch{
        wallet_provider = ?INTEGER,
        destination_provider = ?INTEGER
    },
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, IdentityProviderMismatchException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"This wallet and destination cannot be used together">>}}},
        create_withdrawal_call_api(C)
    ).

-spec create_fail_wallet_inaccessible(config()) -> _.
create_fail_wallet_inaccessible(C) ->
    WalletInaccessibleException = #fistful_WalletInaccessible{
        id = ?STRING
    },
    _ = create_withdrawal_start_mocks(C, fun() -> {throwing, WalletInaccessibleException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Wallet inaccessible">>}}},
        create_withdrawal_call_api(C)
    ).

-spec get_ok(config()) -> _.
get_ok(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_withdrawal_op_ctx(<<"GetWithdrawal">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_withdrawal, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WITHDRAWAL(PartyID)}
            end}
        ],
        C
    ),
    Cash = #{
        <<"amount">> => 10000,
        <<"currency">> => <<"RUB">>
    },
    {ok, #{
        <<"quote">> := #{
            <<"cashFrom">> := Cash,
            <<"cashTo">> := Cash,
            <<"createdAt">> := ?TIMESTAMP,
            <<"expiresOn">> := ?TIMESTAMP
        }
    }} = call_api(
        fun swag_client_wallet_withdrawals_api:get_withdrawal/3,
        #{
            binding => #{
                <<"withdrawalID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec get_failed(config()) -> _.
get_failed(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_withdrawal_op_ctx(<<"GetWithdrawal">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_withdrawal, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WITHDRAWAL_FAILED(PartyID)}
            end}
        ],
        C
    ),
    {ok, #{
        <<"status">> := <<"Failed">>,
        <<"failure">> := #{
            <<"code">> := <<"account_limit_exceeded">>,
            <<"subError">> := #{
                <<"code">> := <<"amount">>,
                <<"subError">> := #{
                    <<"code">> := <<"sub_code_level_1">>,
                    <<"subError">> := #{
                        <<"code">> := <<"sub_code_level_2">>
                    }
                }
            }
        }
    }} = call_api(
        fun swag_client_wallet_withdrawals_api:get_withdrawal/3,
        #{
            binding => #{
                <<"withdrawalID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec get_failed_wo_colon(config()) -> _.
get_failed_wo_colon(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_withdrawal_op_ctx(<<"GetWithdrawal">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_withdrawal, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WITHDRAWAL_FAILED_WO_COLON(PartyID)}
            end}
        ],
        C
    ),
    {ok, #{
        <<"status">> := <<"Failed">>,
        <<"failure">> := #{
            <<"code">> := <<"authorization_failed">>,
            <<"subError">> := #{
                <<"code">> := <<"unknown">>
            }
        }
    }} = call_api(
        fun swag_client_wallet_withdrawals_api:get_withdrawal/3,
        #{
            binding => #{
                <<"withdrawalID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec get_fail_withdrawal_notfound(config()) -> _.
get_fail_withdrawal_notfound(C) ->
    _ = wapi_ct_helper_bouncer:mock_arbiter(wapi_ct_helper_bouncer:judge_always_forbidden(), C),
    _ = wapi_ct_helper:mock_services(
        [
            {fistful_withdrawal, fun
                ('GetContext', _) -> {throwing, #fistful_WithdrawalNotFound{}};
                ('Get', _) -> {throwing, #fistful_WithdrawalNotFound{}}
            end}
        ],
        C
    ),
    ?assertEqual(
        {error, {404, #{}}},
        call_api(
            fun swag_client_wallet_withdrawals_api:get_withdrawal/3,
            #{
                binding => #{
                    <<"withdrawalID">> => ?STRING
                }
            },
            wapi_ct_helper:cfg(context, C)
        )
    ).

-spec get_by_external_id_ok(config()) -> _.
get_by_external_id_ok(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_withdrawal_op_ctx(<<"GetWithdrawalByExternalID">>, ?STRING, PartyID, C),
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun('GetInternalID', _) -> {ok, ?GET_INTERNAL_ID_RESULT} end},
            {fistful_withdrawal, fun
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('Get', _) -> {ok, ?WITHDRAWAL(PartyID)}
            end}
        ],
        C
    ),
    {ok, _} = call_api(
        fun swag_client_wallet_withdrawals_api:get_withdrawal_by_external_id/3,
        #{
            binding => #{
                <<"externalID">> => ?STRING
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec create_quote_ok(config()) -> _.
create_quote_ok(C) ->
    _ = get_quote_start_mocks(C, fun() -> {ok, ?WITHDRAWAL_QUOTE} end),
    {ok, _} = create_qoute_call_api(C).

-spec get_quote_fail_wallet_notfound(config()) -> _.
get_quote_fail_wallet_notfound(C) ->
    _ = get_quote_start_mocks(C, fun() -> {throwing, #fistful_WalletNotFound{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such wallet">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_destination_notfound(config()) -> _.
get_quote_fail_destination_notfound(C) ->
    _ = get_quote_start_mocks(C, fun() -> {throwing, #fistful_DestinationNotFound{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"No such destination">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_destination_unauthorized(config()) -> _.
get_quote_fail_destination_unauthorized(C) ->
    _ = get_quote_start_mocks(C, fun() -> {throwing, #fistful_DestinationUnauthorized{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Destination unauthorized">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_destination_withdrawal_method(config()) -> _.
get_quote_fail_destination_withdrawal_method(C) ->
    _ = get_quote_start_mocks(C, fun() -> {throwing, #fistful_ForbiddenWithdrawalMethod{}} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Destination uses resource no longer allowed">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_forbidden_operation_currency(config()) -> _.
get_quote_fail_forbidden_operation_currency(C) ->
    ForbiddenOperationCurrencyException = #fistful_ForbiddenOperationCurrency{
        currency = #'fistful_base_CurrencyRef'{symbolic_code = ?USD},
        allowed_currencies = [
            #'fistful_base_CurrencyRef'{symbolic_code = ?RUB}
        ]
    },
    _ = get_quote_start_mocks(C, fun() -> {throwing, ForbiddenOperationCurrencyException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Forbidden currency">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_forbidden_operation_amount(config()) -> _.
get_quote_fail_forbidden_operation_amount(C) ->
    ForbiddenOperationAmountException = #fistful_ForbiddenOperationAmount{
        amount = ?CASH,
        allowed_range = #'fistful_base_CashRange'{
            upper = {inclusive, ?CASH},
            lower = {inclusive, ?CASH}
        }
    },
    _ = get_quote_start_mocks(C, fun() -> {throwing, ForbiddenOperationAmountException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid cash amount">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_invalid_operation_amount(config()) -> _.
get_quote_fail_invalid_operation_amount(C) ->
    InvalidOperationAmountException = #fistful_InvalidOperationAmount{
        amount = ?CASH
    },
    _ = get_quote_start_mocks(C, fun() -> {throwing, InvalidOperationAmountException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid cash amount">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_inconsistent_withdrawal_currency(config()) -> _.
get_quote_fail_inconsistent_withdrawal_currency(C) ->
    InconsistentWithdrawalCurrencyException = #wthd_InconsistentWithdrawalCurrency{
        withdrawal_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?USD
        },
        destination_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?RUB
        },
        wallet_currency = #'fistful_base_CurrencyRef'{
            symbolic_code = ?RUB
        }
    },
    _ = get_quote_start_mocks(C, fun() -> {throwing, InconsistentWithdrawalCurrencyException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"Invalid currency">>}}},
        create_qoute_call_api(C)
    ).

-spec get_quote_fail_identity_provider_mismatch(config()) -> _.
get_quote_fail_identity_provider_mismatch(C) ->
    IdentityProviderMismatchException = #wthd_IdentityProvidersMismatch{
        wallet_provider = ?INTEGER,
        destination_provider = ?INTEGER
    },
    _ = get_quote_start_mocks(C, fun() -> {throwing, IdentityProviderMismatchException} end),
    ?assertEqual(
        {error, {422, #{<<"message">> => <<"This wallet and destination cannot be used together">>}}},
        create_qoute_call_api(C)
    ).

-spec get_event_ok(config()) -> _.
get_event_ok(C) ->
    _ = get_events_start_mocks(<<"GetWithdrawalEvents">>, C, fun() -> {ok, []} end),
    {ok, _} = call_api(
        fun swag_client_wallet_withdrawals_api:get_withdrawal_events/3,
        #{
            binding => #{
                <<"withdrawalID">> => ?STRING,
                <<"eventID">> => ?INTEGER
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec get_events_ok(config()) -> _.
get_events_ok(C) ->
    _ = get_events_start_mocks(<<"PollWithdrawalEvents">>, C, fun() -> {ok, []} end),
    {ok, _} = call_api(
        fun swag_client_wallet_withdrawals_api:poll_withdrawal_events/3,
        #{
            binding => #{
                <<"withdrawalID">> => ?STRING
            },
            qs_val => #{
                <<"limit">> => 10
            }
        },
        wapi_ct_helper:cfg(context, C)
    ).

-spec get_events_fail_withdrawal_notfound(config()) -> _.
get_events_fail_withdrawal_notfound(C) ->
    _ = get_events_start_mocks(<<"PollWithdrawalEvents">>, C, fun() -> {throwing, #fistful_WithdrawalNotFound{}} end),
    ?assertEqual(
        {error, {404, #{}}},
        call_api(
            fun swag_client_wallet_withdrawals_api:poll_withdrawal_events/3,
            #{
                binding => #{
                    <<"withdrawalID">> => ?STRING
                },
                qs_val => #{
                    <<"limit">> => 10
                }
            },
            wapi_ct_helper:cfg(context, C)
        )
    ).

-spec check_unknown_withdrawal_id(config()) -> _.
check_unknown_withdrawal_id(C) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_generic_op_ctx(
        [
            {destination, ?STRING, PartyID},
            {wallet, ?STRING, PartyID}
        ],
        ?CTX_WAPI(#ctx_v1_WalletAPIOperation{
            id = <<"CreateWithdrawal">>,
            destination = ?STRING,
            wallet = ?STRING
        }),
        C
    ),
    CounterRef = counters:new(1, []),
    ID0 = <<"Test0">>,
    ID1 = <<"Test1">>,
    Withdrawal0 = ?WITHDRAWAL(PartyID),
    Withdrawal1 = Withdrawal0#wthd_WithdrawalState{id = ID1},
    Withdrawal2 = Withdrawal1#wthd_WithdrawalState{id = ID0, wallet_id = ?STRING2},
    _ = wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) ->
                CID = counters:get(CounterRef, 1),
                BinaryCID = erlang:integer_to_binary(CID),
                ok = counters:add(CounterRef, 1, 1),
                {ok, ?GENERATE_ID_RESULT(<<"Test", BinaryCID/binary>>)}
            end},
            {fistful_wallet, fun
                ('Get', _) -> {ok, ?WALLET(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_destination, fun
                ('Get', _) -> {ok, ?DESTINATION(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_withdrawal, fun
                ('Create', _) ->
                    {ok, Withdrawal1};
                ('Get', {WID, _}) when WID =:= ID0 ->
                    {ok, Withdrawal2};
                ('Get', {WID, _}) when WID =:= ID1 ->
                    {throwing, #fistful_WithdrawalNotFound{}}
            end}
        ],
        C
    ),
    {ok, #{
        <<"id">> := ID1
    }} = create_withdrawal_call_api(C).

%%

-spec call_api(function(), map(), wapi_client_lib:context()) -> {ok, term()} | {error, term()}.
call_api(F, Params, Context) ->
    {Url, PreparedParams, Opts} = wapi_client_lib:make_request(Context, Params),
    Response = F(Url, PreparedParams, Opts),
    wapi_client_lib:handle_response(Response).

create_withdrawal_call_api(C) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:create_withdrawal/3,
        #{
            body => genlib_map:compact(#{
                <<"wallet">> => ?STRING,
                <<"destination">> => ?STRING,
                <<"body">> => #{
                    <<"amount">> => ?INTEGER,
                    <<"currency">> => ?RUB
                }
            })
        },
        wapi_ct_helper:cfg(context, C)
    ).

create_qoute_call_api(C) ->
    call_api(
        fun swag_client_wallet_withdrawals_api:create_quote/3,
        #{
            body => genlib_map:compact(#{
                <<"walletID">> => ?STRING,
                <<"destinationID">> => ?STRING,
                <<"currencyFrom">> => ?RUB,
                <<"currencyTo">> => ?USD,
                <<"cash">> => #{
                    <<"amount">> => ?INTEGER,
                    <<"currency">> => ?RUB
                }
            })
        },
        wapi_ct_helper:cfg(context, C)
    ).

create_withdrawal_start_mocks(C, CreateWithdrawalResultFun) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_generic_op_ctx(
        [
            {destination, ?STRING, PartyID},
            {wallet, ?STRING, PartyID}
        ],
        ?CTX_WAPI(#ctx_v1_WalletAPIOperation{
            id = <<"CreateWithdrawal">>,
            destination = ?STRING,
            wallet = ?STRING
        }),
        C
    ),
    wapi_ct_helper:mock_services(
        [
            {bender, fun('GenerateID', _) -> {ok, ?GENERATE_ID_RESULT} end},
            {fistful_wallet, fun
                ('Get', _) -> {ok, ?WALLET(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_destination, fun
                ('Get', _) -> {ok, ?DESTINATION(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_withdrawal, fun
                ('Create', _) -> CreateWithdrawalResultFun();
                ('Get', _) -> {throwing, #fistful_WithdrawalNotFound{}}
            end}
        ],
        C
    ).

get_events_start_mocks(Op, C, GetEventRangeResultFun) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_withdrawal_op_ctx(Op, ?STRING, PartyID, C),
    wapi_ct_helper:mock_services(
        [
            {fistful_withdrawal, fun
                ('Get', _) -> {ok, ?WITHDRAWAL(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)};
                ('GetEvents', {_, #'fistful_base_EventRange'{limit = 0}}) -> GetEventRangeResultFun();
                ('GetEvents', _) -> {ok, [?WITHDRAWAL_EVENT(?WITHDRAWAL_STATUS_CHANGE)]}
            end}
        ],
        C
    ).

get_quote_start_mocks(C, GetQuoteResultFun) ->
    PartyID = ?config(party, C),
    _ = wapi_ct_helper_bouncer:mock_assert_generic_op_ctx(
        [
            {destination, ?STRING, PartyID},
            {wallet, ?STRING, PartyID}
        ],
        ?CTX_WAPI(#ctx_v1_WalletAPIOperation{
            id = <<"CreateQuote">>,
            destination = ?STRING,
            wallet = ?STRING
        }),
        C
    ),
    wapi_ct_helper:mock_services(
        [
            {fistful_wallet, fun
                ('Get', _) -> {ok, ?WALLET(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_destination, fun
                ('Get', _) -> {ok, ?DESTINATION(PartyID)};
                ('GetContext', _) -> {ok, ?DEFAULT_CONTEXT(PartyID)}
            end},
            {fistful_withdrawal, fun('GetQuote', _) -> GetQuoteResultFun() end}
        ],
        C
    ).
