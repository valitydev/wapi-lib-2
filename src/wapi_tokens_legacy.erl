-module(wapi_tokens_legacy).

-export([issue_access_token/2]).
-export([issue_access_token/3]).

-export([get_verification_options/0]).
-export([get_resource_hierarchy/0]).
-export([get_access_config/0]).
-export([get_signee/0]).

-type token_spec() ::
    {destinations, DestinationID :: binary()}
    | {wallets, WalletID :: binary(), Asset :: map()}.

-define(DOMAIN, <<"wallet-api">>).

%%

-spec issue_access_token(wapi_handler_utils:owner(), token_spec()) -> uac_authorizer_jwt:token().
issue_access_token(PartyID, TokenSpec) ->
    issue_access_token(PartyID, TokenSpec, unlimited).

-spec issue_access_token(wapi_handler_utils:owner(), token_spec(), uac_authorizer_jwt:expiration()) ->
    uac_authorizer_jwt:token().
issue_access_token(PartyID, TokenSpec, Expiration) ->
    Claims0 = resolve_token_spec(TokenSpec),
    Claims = Claims0#{<<"exp">> => Expiration},
    wapi_utils:unwrap(
        uac_authorizer_jwt:issue(
            wapi_utils:get_unique_id(),
            PartyID,
            Claims,
            get_signee()
        )
    ).

-spec get_access_config() -> map().
get_access_config() ->
    #{
        domain_name => ?DOMAIN,
        resource_hierarchy => get_resource_hierarchy()
    }.

-spec get_resource_hierarchy() -> #{atom() => map()}.
get_resource_hierarchy() ->
    #{
        party => #{
            wallets => #{},
            destinations => #{}
        },
        w2w => #{},
        webhooks => #{},
        withdrawals => #{withdrawal_quotes => #{}}
    }.

-spec get_verification_options() -> uac:verification_opts().
get_verification_options() ->
    #{}.

-spec get_signee() -> term().
get_signee() ->
    wapi_utils:unwrap(application:get_env(wapi_lib, signee)).

%%

resolve_token_spec({destinations, DestinationID}) ->
    #{
        <<"resource_access">> => #{
            ?DOMAIN => uac_acl:from_list(
                [{[party, {destinations, DestinationID}], write}]
            )
        }
    };
resolve_token_spec({wallets, WalletID, #{<<"amount">> := Amount, <<"currency">> := Currency}}) ->
    #{
        <<"amount">> => Amount,
        <<"currency">> => Currency,
        <<"resource_access">> => #{
            ?DOMAIN => uac_acl:from_list(
                [{[party, {wallets, WalletID}], write}]
            )
        }
    }.
