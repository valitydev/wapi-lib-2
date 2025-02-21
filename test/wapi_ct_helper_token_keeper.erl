-module(wapi_ct_helper_token_keeper).

-include_lib("wapi_wallet_dummy_data.hrl").
-include_lib("token_keeper_proto/include/tk_token_keeper_thrift.hrl").
-include_lib("bouncer_proto/include/bouncer_ctx_thrift.hrl").
-include_lib("wapi_token_keeper_data.hrl").

-define(USER_EMAIL, <<"bla@bla.ru">>).
-define(TOKEN_LIFETIME, 259200).

-type sup_or_config() :: wapi_ct_helper:sup_or_config().
-type app_name() :: wapi_ct_helper:app_name().
-type token_handler() :: fun(('GetByToken', tuple()) -> term() | no_return()).

-export([mock_token/2]).
-export([mock_user_session_token/2]).

-spec mock_token(token_handler(), sup_or_config()) -> list(app_name()).
mock_token(HandlerFun, SupOrConfig) ->
    start_client(wapi_ct_helper:mock_services_([{token_authenticator, HandlerFun}], SupOrConfig)).

start_client(ServiceURLs) ->
    wapi_ct_helper:start_app(token_keeper_client, [
        {service_clients, #{
            authenticator => #{
                url => maps:get(token_authenticator, ServiceURLs)
            },
            authorities => #{
                ephemeral => #{},
                offline => #{}
            }
        }}
    ]).

%%

-spec mock_user_session_token(binary(), sup_or_config()) -> list(app_name()).
mock_user_session_token(UserID, SupOrConfig) ->
    Handler = make_authenticator_handler(fun() ->
        UserParams = #{
            id => UserID,
            realm => #{id => <<"external">>},
            email => ?USER_EMAIL
        },
        AuthParams = #{
            method => <<"SessionToken">>,
            expiration => posix_to_rfc3339(lifetime_to_expiration(?TOKEN_LIFETIME)),
            token => #{id => ?STRING}
        },
        {?TK_AUTHORITY_KEYCLOAK, create_bouncer_context(AuthParams, UserParams), user_session_metadata(UserID)}
    end),
    mock_token(Handler, SupOrConfig).

%%

-spec make_authenticator_handler(function()) -> token_handler().
make_authenticator_handler(Handler) ->
    fun('Authenticate', {Token, _}) ->
        {Authority, ContextFragment, Metadata} = Handler(),
        AuthData = #token_keeper_AuthData{
            token = Token,
            status = active,
            context = ContextFragment,
            authority = Authority,
            metadata = Metadata
        },
        {ok, AuthData}
    end.

%%

user_session_metadata(UserID) ->
    genlib_map:compact(#{
        ?TK_META_USER_ID => UserID,
        ?TK_META_USER_EMAIL => ?USER_EMAIL
    }).

%%

create_bouncer_context(AuthParams, UserParams) ->
    Fragment0 = bouncer_context_helpers:make_auth_fragment(AuthParams),
    Fragment1 = bouncer_context_helpers:add_user(UserParams, Fragment0),
    encode_context(Fragment1).
%%

encode_context(Context) ->
    #ctx_ContextFragment{
        type = v1_thrift_binary,
        content = encode_context_content(Context)
    }.

encode_context_content(Context) ->
    Type = {struct, struct, {bouncer_ctx_v1_thrift, 'ContextFragment'}},
    Codec = thrift_strict_binary_codec:new(),
    {ok, Codec1} = thrift_strict_binary_codec:write(Codec, Type, Context),
    thrift_strict_binary_codec:close(Codec1).

%%

lifetime_to_expiration(Lt) when is_integer(Lt) ->
    genlib_time:unow() + Lt.

posix_to_rfc3339(Timestamp) when is_integer(Timestamp) ->
    genlib_rfc3339:format(Timestamp, second).
