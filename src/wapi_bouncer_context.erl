-module(wapi_bouncer_context).

-include_lib("bouncer_proto/include/bouncer_ctx_v1_thrift.hrl").
-include_lib("bouncer_proto/include/bouncer_base_thrift.hrl").

-type fragment() :: bouncer_client:context_fragment().
-type acc() :: bouncer_context_helpers:context_fragment().

-type fragments() :: {acc(), _ExternalFragments :: #{_ID => fragment()}}.

-export_type([fragment/0]).
-export_type([acc/0]).
-export_type([fragments/0]).

-type operation_id() :: wapi_handler_utils:operation_id().
-type prototypes() :: [
    {operation, prototype_operation()}
    | {wallet, prototype_wallet()}
].

-type prototype_operation() :: #{
    id => operation_id(),
    party => maybe_undefined(entity_id()),
    identity => maybe_undefined(entity_id()),
    wallet => maybe_undefined(entity_id()),
    withdrawal => maybe_undefined(entity_id()),
    deposit => maybe_undefined(entity_id()),
    w2w_transfer => maybe_undefined(entity_id()),
    source => maybe_undefined(entity_id()),
    destination => maybe_undefined(entity_id()),
    report => maybe_undefined(entity_id()),
    file => maybe_undefined(entity_id()),
    webhook => maybe_undefined(entity_id())
}.

-type prototype_wallet() :: [wallet_entity()].

-type wallet_entity() ::
    {identity, identity_data()}
    | {wallet, wallet_data()}
    | {withdrawal, withdrawal_data()}
    | {deposit, deposit_data()}
    | {w2w_transfer, w2w_transfer_data()}
    | {source, source_data()}
    | {destination, destination_data()}
    | {webhook, webhook_data()}
    | {report, report_data()}.

-type wallet_entity_type() ::
    identity
    | wallet
    | withdrawal
    | deposit
    | w2w_transfer
    | source
    | destination
    | webhook
    | webhook_filter
    | report
    | report_file.

-type identity_data() :: #{
    id => entity_id()
}.

-type wallet_data() :: #{
    id => entity_id(),
    party => entity_id(),
    cash => cash()
}.

-type withdrawal_data() :: #{
    id => entity_id(),
    party => entity_id()
}.

-type deposit_data() :: #{
    id => entity_id(),
    party => entity_id()
}.

-type w2w_transfer_data() :: #{
    id => entity_id(),
    party => entity_id()
}.

-type source_data() :: #{
    id => entity_id(),
    party => entity_id()
}.

-type destination_data() :: #{
    id => entity_id(),
    party => entity_id()
}.

-type webhook_data() :: #{
    id => entity_id(),
    identity => entity_id(),
    wallet => entity_id()
}.

-type report_data() :: #{
    id => entity_id(),
    identity => entity_id(),
    files => [entity_id()]
}.

-type entity_id() :: binary().
-type maybe_undefined(Type) :: Type | undefined.
-type cash() :: #{amount := binary(), currency := binary()}.

-export_type([prototypes/0]).
-export_type([prototype_operation/0]).
-export_type([prototype_wallet/0]).
-export_type([wallet_entity_type/0]).

-export([new/0]).
-export([build/2]).
-export([build_wallet_entity/2]).
-export([build_wallet_entity/3]).

%%

-spec new() -> fragments().
new() ->
    {mk_base_fragment(), #{}}.

mk_base_fragment() ->
    bouncer_context_helpers:make_env_fragment(#{
        now => genlib_rfc3339:format(genlib_time:unow(), second),
        deployment => #{id => genlib_app:env(wapi_lib, deployment, undefined)}
    }).

-spec build(prototypes(), fragments()) -> fragments().
build(Prototypes, {Acc0, External}) ->
    Acc1 = lists:foldl(fun({T, Params}, Acc) -> build(T, Params, Acc) end, Acc0, Prototypes),
    {Acc1, External}.

build(operation, #{id := OperationID} = Params, Acc) ->
    Acc#ctx_v1_ContextFragment{
        wapi = #ctx_v1_ContextWalletAPI{
            op = #ctx_v1_WalletAPIOperation{
                id = operation_id_to_binary(OperationID),
                party = 'maybe'(party, Params),
                identity = 'maybe'(identity, Params),
                wallet = 'maybe'(wallet, Params),
                withdrawal = 'maybe'(withdrawal, Params),
                deposit = 'maybe'(deposit, Params),
                w2w_transfer = 'maybe'(w2w_transfer, Params),
                source = 'maybe'(source, Params),
                destination = 'maybe'(destination, Params),
                report = wapi_handler_utils:maybe_with(report, Params, fun genlib:to_binary/1),
                file = 'maybe'(file, Params),
                webhook = 'maybe'(webhook, Params)
            },
            grants = wapi_handler_utils:maybe_with(grants, Params, fun build_grants/1)
        }
    };
build(wallet, Params, Acc) when is_list(Params) ->
    Acc#ctx_v1_ContextFragment{
        wallet = build_set(lists:map(fun build_entity_ctx/1, Params))
    }.

-spec build_wallet_entity(wallet_entity_type(), map()) -> wallet_entity().
build_wallet_entity(Type, Data) ->
    build_wallet_entity(Type, Data, {undefined, undefined}).

-spec build_wallet_entity(wallet_entity_type(), map() | undefined, {atom() | undefined, entity_id() | undefined}) ->
    wallet_entity().
build_wallet_entity(Type, undefined, _) ->
    {Type, undefined};
build_wallet_entity(report = Type, Params, {IDKey, ID}) ->
    EntityID =
        case maps:get(<<"id">>, Params, undefined) of
            undefined ->
                undefined;
            Result ->
                genlib:to_binary(Result)
        end,
    {Type,
        maps:merge(
            genlib_map:compact(#{
                IDKey => ID,
                id => EntityID
            }),
            build_wallet_entity_(Type, Params)
        )};
build_wallet_entity(Type, Params, {IDKey, ID}) ->
    {Type,
        maps:merge(
            genlib_map:compact(#{
                IDKey => ID,
                id => maps:get(<<"id">>, Params, undefined)
            }),
            build_wallet_entity_(Type, Params)
        )}.

build_wallet_entity_(deposit, #{<<"wallet">> := WalletID}) ->
    #{wallet => WalletID};
build_wallet_entity_(webhook, #{<<"identityID">> := Identity} = Webhook) ->
    Scope = 'maybe'(<<"scope">>, Webhook),
    WalletID = 'maybe'(<<"walletID">>, Scope),
    #{identity => Identity, wallet => WalletID};
build_wallet_entity_(report, #{<<"files">> := Files}) ->
    #{files => lists:map(fun(#{<<"id">> := FileID}) -> FileID end, Files)};
%% identity => IdentityID,
build_wallet_entity_(_, _) ->
    #{}.

%%

build_entity_ctx({identity, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"Identity">>,
        party = 'maybe'(party, Data)
    };
build_entity_ctx({wallet, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"Wallet">>,
        party = 'maybe'(party, Data),
        wallet = #base_WalletAttrs{
            body = wapi_handler_utils:maybe_with(cash, Data, fun build_cash/1)
        }
    };
build_entity_ctx({withdrawal, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"Withdrawal">>,
        party = 'maybe'(party, Data)
    };
build_entity_ctx({deposit, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"Deposit">>,
        wallet = #base_WalletAttrs{
            wallet = 'maybe'(wallet, Data)
        }
    };
build_entity_ctx({w2w_transfer, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"W2WTransfer">>,
        party = 'maybe'(party, Data)
    };
build_entity_ctx({source, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"Source">>,
        party = 'maybe'(party, Data)
    };
build_entity_ctx({destination, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"Destination">>,
        party = 'maybe'(party, Data)
    };
build_entity_ctx({webhook, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"WalletWebhook">>,
        wallet = #base_WalletAttrs{
            identity = 'maybe'(identity, Data),
            wallet = 'maybe'(wallet, Data)
        }
    };
build_entity_ctx({report, Data}) ->
    #base_Entity{
        id = 'maybe'(id, Data),
        type = <<"WalletReport">>,
        wallet = #base_WalletAttrs{
            identity = 'maybe'(identity, Data),
            report = wapi_handler_utils:maybe_with(files, Data, fun build_report_attrs/1)
        }
    }.

%%

'maybe'(_Name, undefined) ->
    undefined;
'maybe'(Name, Params) ->
    maps:get(Name, Params, undefined).

operation_id_to_binary(V) ->
    erlang:atom_to_binary(V, utf8).

build_grants(Grants) when is_list(Grants) ->
    build_set(lists:map(fun build_grant/1, Grants)).

build_grant(Grant) ->
    #ctx_v1_WalletGrant{
        wallet = 'maybe'(wallet, Grant),
        destination = 'maybe'(destination, Grant),
        body = wapi_handler_utils:maybe_with(body, Grant, fun build_cash/1),
        created_at = 'maybe'(created_at, Grant),
        expires_on = 'maybe'(expires_on, Grant)
    }.

build_cash(Cash) ->
    #base_Cash{
        amount = 'maybe'(amount, Cash),
        currency = 'maybe'(currency, Cash)
    }.

build_set(L) when is_list(L) ->
    ordsets:from_list(L).

build_report_attrs(Attrs) when is_list(Attrs) ->
    #base_WalletReportAttrs{
        files = build_set(Attrs)
    }.
