-module(wapi_ct_helper_handler).

-behaviour(swag_server_wallet_logic_handler).

%% swag_server_wallet_logic_handler callbacks
-export([map_error/2]).
-export([authorize_api_key/4]).
-export([handle_request/4]).

%% API

-spec map_error(atom(), swag_server_wallet_validation:error()) -> swag_server_wallet:error_reason().
map_error(validation_error, Error) ->
    Type = map_error_type(maps:get(type, Error)),
    Name = genlib:to_binary(maps:get(param_name, Error)),
    Message =
        case maps:get(description, Error, undefined) of
            undefined ->
                <<"Request parameter: ", Name/binary, ", error type: ", Type/binary>>;
            Description ->
                DescriptionBin = genlib:to_binary(Description),
                <<"Request parameter: ", Name/binary, ", error type: ", Type/binary, ", description: ",
                    DescriptionBin/binary>>
        end,
    jsx:encode(#{
        <<"errorType">> => Type,
        <<"name">> => Name,
        <<"description">> => Message
    }).

-spec map_error_type(swag_server_wallet_validation:error_type()) -> binary().
map_error_type(no_match) -> <<"NoMatch">>;
map_error_type(not_found) -> <<"NotFound">>;
map_error_type(not_in_range) -> <<"NotInRange">>;
map_error_type(wrong_length) -> <<"WrongLength">>;
map_error_type(wrong_size) -> <<"WrongSize">>;
map_error_type(schema_violated) -> <<"SchemaViolated">>;
map_error_type(wrong_type) -> <<"WrongType">>;
map_error_type(wrong_body) -> <<"WrongBody">>;
map_error_type(wrong_array) -> <<"WrongArray">>.

-spec authorize_api_key(
    wapi_handler_utils:operation_id(),
    wapi_auth:api_key(),
    wapi_handler_utils:request_context(),
    wapi_wallet_handler:handler_opts()
) ->
    Result :: false | {true, wapi_auth:preauth_context()}.
authorize_api_key(OperationID, ApiKey, _Context, _HandlerOpts) ->
    %% Since we require the request id field to create a woody context for our trip to token_keeper
    %% it seems it is no longer possible to perform any authorization in this method.
    %% To gain this ability back be would need to rewrite the swagger generator to perform its
    %% request validation checks before this stage.
    %% But since a decent chunk of authorization logic is already defined in the handler function
    %% it is probably easier to move it there in its entirety.
    ok = scoper:add_scope('swag.server', #{api => wallet, operation_id => OperationID}),
    case wapi_auth:preauthorize_api_key(ApiKey) of
        {ok, Context} ->
            {true, Context};
        {error, Error} ->
            _ = logger:info("API Key preauthorization failed for ~p due to ~p", [OperationID, Error]),
            false
    end.

-spec handle_request(
    swag_server_wallet:operation_id(),
    wapi_wallet_handler:request_data(),
    wapi_handler_utils:request_context(),
    wapi_wallet_handler:handler_opts()
) ->
    wapi_wallet_handler:request_result().
handle_request(OperationID, Req, SwagContext, Opts) ->
    #{'X-Request-Deadline' := Header} = Req,
    case wapi_utils:parse_deadline(Header) of
        {ok, Deadline} ->
            WoodyContext = attach_deadline(Deadline, create_woody_context(Req)),
            process_request(OperationID, Req, SwagContext, Opts, WoodyContext);
        _ ->
            wapi_handler_utils:reply_ok(400, #{
                <<"errorType">> => <<"SchemaViolated">>,
                <<"name">> => <<"X-Request-Deadline">>,
                <<"description">> => <<"Invalid data in X-Request-Deadline header">>
            })
    end.

process_request(OperationID, Req, SwagContext0, Opts, WoodyContext) ->
    _ = logger:info("Processing request ~p", [OperationID]),
    try
        SwagContext = do_authorize_api_key(SwagContext0, WoodyContext),
        Context = create_handler_context(OperationID, SwagContext, WoodyContext),
        {ok, RequestState} = wapi_wallet_handler:prepare(OperationID, Req, Context, Opts),
        #{authorize := Authorize, process := Process} = RequestState,
        {ok, Resolution} = Authorize(),
        case Resolution of
            allowed ->
                ok = logger:debug("Operation ~p authorized", [OperationID]),
                Process();
            forbidden ->
                _ = logger:info("Authorization failed"),
                wapi_handler_utils:reply_ok(401);
            Result ->
                Result
        end
    catch
        throw:{token_auth_failed, Reason} ->
            _ = logger:info("API Key authorization failed for ~p due to ~p", [OperationID, Reason]),
            wapi_handler_utils:reply_ok(401);
        error:{woody_error, {Source, Class, Details}} ->
            process_woody_error(Source, Class, Details)
    end.

-spec create_woody_context(wapi_wallet_handler:request_data()) -> woody_context:ctx().
create_woody_context(#{'X-Request-ID' := RequestID}) ->
    RpcID = #{trace_id := TraceID} = woody_context:new_rpc_id(genlib:to_binary(RequestID)),
    ok = scoper:add_meta(#{request_id => RequestID, trace_id => TraceID}),
    woody_context:new(RpcID, undefined, wapi_woody_client:get_service_deadline(wallet)).

attach_deadline(undefined, Context) ->
    Context;
attach_deadline(Deadline, Context) ->
    woody_context:set_deadline(Deadline, Context).

do_authorize_api_key(#{auth_context := PreAuthContext} = SwagContext, WoodyContext) ->
    case wapi_auth:authorize_api_key(PreAuthContext, make_token_context(SwagContext), WoodyContext) of
        {ok, AuthContext} ->
            SwagContext#{auth_context => AuthContext};
        {error, Error} ->
            throw({token_auth_failed, Error})
    end.

make_token_context(#{cowboy_req := CowboyReq}) ->
    case cowboy_req:header(<<"origin">>, CowboyReq) of
        Origin when is_binary(Origin) ->
            #{request_origin => Origin};
        undefined ->
            #{}
    end.

-spec create_handler_context(
    wapi_handler_utils:operation_id(), wapi_handler_utils:request_context(), woody_context:ctx()
) -> wapi_handler_utils:handler_context().
create_handler_context(OpID, SwagContext, WoodyContext) ->
    #{
        operation_id => OpID,
        woody_context => WoodyContext,
        swagger_context => SwagContext,
        swag_server_get_schema_fun => fun swag_server_wallet_schema:get/0,
        swag_server_get_operation_fun => fun(OperationID) -> swag_server_wallet_router:get_operation(OperationID) end
    }.

process_woody_error(_Source, result_unexpected, _Details) ->
    wapi_handler_utils:reply_error(500);
process_woody_error(_Source, resource_unavailable, _Details) ->
    % Return an 504 since it is unknown if state of the system has been altered
    % @TODO Implement some sort of tagging for operations that mutate the state,
    % so we can still return 503s for those that don't
    wapi_handler_utils:reply_error(504);
process_woody_error(_Source, result_unknown, _Details) ->
    wapi_handler_utils:reply_error(504).
